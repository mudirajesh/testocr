import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/detected_barcode.dart';
import '../utils/constants.dart';
import '../utils/luminance.dart';

class CameraUnavailableException implements Exception {
  @override
  String toString() => 'CameraUnavailableException';
}

class CameraPermissionDeniedException implements Exception {
  const CameraPermissionDeniedException({this.permanent = false});

  /// True when the system will not ask again ("Don't ask again" / restricted):
  /// the only way forward is the app settings.
  final bool permanent;

  @override
  String toString() => 'CameraPermissionDeniedException(permanent: $permanent)';
}

/// Source of barcode detections. The provider depends on this interface so it
/// can be tested with a fake instead of a real camera.
abstract class BarcodeDetectionSource {
  /// A processed frame: the centremost barcode, or null when none was seen.
  Stream<DetectedBarcode?> get detections;

  /// Mean frame brightness (0..255), smoothed over the last few frames.
  Stream<double> get brightness;

  /// Runtime failures (camera disconnected, the stream failing repeatedly).
  /// After one is emitted the image stream has been stopped.
  Stream<Object> get errors;

  /// Whether the camera can zoom to [kAutoZoomLevel].
  bool get supportsZoom;

  /// Average time of one ML Kit call over the recent frames (ms), 0 if none.
  double get averageFrameMillis;

  /// May throw [CameraUnavailableException] / [CameraPermissionDeniedException].
  Future<void> start();

  /// Stops the image stream but keeps the camera open.
  Future<void> pause();
  Future<void> resume();

  /// Returns false when the device has no flash or turning it on/off failed.
  Future<bool> setTorch(bool on);

  /// Clamped to what the camera supports.
  Future<void> setZoom(double level);

  /// Current camera permission, without prompting.
  Future<bool> isCameraPermissionGranted();

  /// Captures a still picture from the camera. The stream must be paused first.
  Future<String?> takePicture();

  /// Stops the stream, releases the camera and closes ML Kit. Safe to call
  /// twice; [start] may be called again afterwards.
  Future<void> dispose();

  CameraController? get cameraController;
}

/// Camera + ML Kit implementation for Android.
class MlKitBarcodeSource implements BarcodeDetectionSource {
  final StreamController<DetectedBarcode?> _detections =
      StreamController<DetectedBarcode?>.broadcast();
  final StreamController<double> _brightness =
      StreamController<double>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();

  /// Frames in a row that threw before the source gives up.
  static const _maxFrameErrors = 5;
  static const _brightnessWindow = 5;

  CameraController? _camera;
  BarcodeScanner? _scanner;
  bool _busy = false;
  bool _streaming = false;
  bool _failed = false;
  int _frameErrors = 0;
  DateTime? _lastFrameAt;
  double _minZoom = 1;
  double _maxZoom = 1;
  final List<double> _recentBrightness = [];
  final List<int> _recentFrameMillis = [];

  /// Bumped on every dispose so a frame still in flight from a released camera
  /// cannot emit.
  int _session = 0;

  @override
  Stream<DetectedBarcode?> get detections => _detections.stream;

  @override
  Stream<double> get brightness => _brightness.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  CameraController? get cameraController => _camera;

  @override
  bool get supportsZoom => _maxZoom >= kAutoZoomLevel;

  @override
  double get averageFrameMillis => _recentFrameMillis.isEmpty
      ? 0
      : _recentFrameMillis.reduce((a, b) => a + b) / _recentFrameMillis.length;

  @override
  Future<bool> isCameraPermissionGranted() async =>
      (await Permission.camera.status).isGranted;

  @override
  Future<void> start() async {
    await dispose(); // never leave a previous camera open
    _failed = false;
    _frameErrors = 0;
    _recentBrightness.clear();
    _recentFrameMillis.clear();

    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } on CameraException catch (e) {
      debugPrint('availableCameras failed: $e');
      throw CameraUnavailableException();
    }
    final back = cameras
        .where((c) => c.lensDirection == CameraLensDirection.back)
        .firstOrNull;
    if (back == null) throw CameraUnavailableException();

    // Check first, ask only if needed. A permanent denial (or a restricted
    // device) cannot be fixed by asking again.
    var status = await Permission.camera.status;
    if (!status.isGranted) status = await Permission.camera.request();
    if (!status.isGranted) {
      throw CameraPermissionDeniedException(
        permanent: status.isPermanentlyDenied || status.isRestricted,
      );
    }

    final controller = CameraController(
      back,
      kCameraResolution,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21, // what ML Kit wants on Android
    );
    _camera = controller;
    _scanner = BarcodeScanner(
      formats: [
        BarcodeFormat.code128,
        BarcodeFormat.dataMatrix,
        BarcodeFormat.qrCode,
        BarcodeFormat.ean13,
        BarcodeFormat.ean8,
      ],
    );

    try {
      await controller.initialize();
    } on CameraException catch (e) {
      debugPrint('Camera initialize failed: $e');
      final denied = e.code.toLowerCase().contains('denied');
      await dispose();
      throw denied
          ? const CameraPermissionDeniedException()
          : CameraUnavailableException();
    }
    controller.addListener(_onControllerChanged);

    // Some devices throw on these, so each is best-effort.
    await _tryCamera(
      'lockCaptureOrientation',
      () => controller.lockCaptureOrientation(DeviceOrientation.portraitUp),
    );
    await _tryCamera(
      'setFocusMode',
      () => controller.setFocusMode(FocusMode.auto),
    );
    await _tryCamera(
      'setExposureMode',
      () => controller.setExposureMode(ExposureMode.auto),
    );
    await _tryCamera('zoom range', () async {
      _minZoom = await controller.getMinZoomLevel();
      _maxZoom = await controller.getMaxZoomLevel();
    });

    await _startStream();
  }

  Future<void> _tryCamera(String name, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('$name failed: $e');
    }
  }

  /// A controller error event (e.g. the camera was disconnected).
  void _onControllerChanged() {
    final value = _camera?.value;
    if (value != null && value.hasError) {
      _fail(value.errorDescription ?? 'Camera error');
    }
  }

  void _fail(Object error) {
    if (_failed) return;
    _failed = true;
    debugPrint('Camera failed: $error');
    unawaited(pause());
    if (!_errors.isClosed) _errors.add(error);
  }

  Future<void> _startStream() async {
    final camera = _camera;
    if (camera == null || _streaming || !camera.value.isInitialized) return;
    _streaming = true;
    await camera.startImageStream(_onFrame);
  }

  @override
  Future<void> pause() async {
    final camera = _camera;
    if (camera == null || !_streaming) return;
    _streaming = false;
    try {
      await camera.stopImageStream();
    } catch (e) {
      debugPrint('stopImageStream failed: $e');
    }
  }

  @override
  Future<void> resume() async {
    if (_failed) return; // a failed camera needs a full start()
    try {
      await _startStream();
    } catch (e) {
      _streaming = false;
      debugPrint('resume failed: $e');
    }
  }

  @override
  Future<bool> setTorch(bool on) async {
    final camera = _camera;
    if (camera == null) return false;
    try {
      await camera.setFlashMode(on ? FlashMode.torch : FlashMode.off);
      return true;
    } catch (e) {
      debugPrint('setTorch failed: $e');
      return false;
    }
  }

  @override
  Future<void> setZoom(double level) async {
    final camera = _camera;
    if (camera == null) return;
    try {
      await camera.setZoomLevel(level.clamp(_minZoom, _maxZoom));
    } catch (e) {
      debugPrint('setZoom failed: $e');
    }
  }

  @override
  Future<String?> takePicture() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return null;
    try {
      if (_streaming) {
        await pause();
      }
      final xFile = await camera.takePicture();
      return xFile.path;
    } catch (e) {
      debugPrint('takePicture failed: $e');
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    _session++;
    final camera = _camera;
    final scanner = _scanner;
    _camera = null;
    _scanner = null;
    _busy = false;
    _minZoom = 1;
    _maxZoom = 1;

    if (camera != null) {
      camera.removeListener(_onControllerChanged);
      if (_streaming) {
        try {
          await camera.stopImageStream();
        } catch (_) {}
      }
      try {
        await camera.dispose();
      } catch (e) {
        debugPrint('camera dispose failed: $e');
      }
    }
    _streaming = false;
    try {
      await scanner?.close();
    } catch (e) {
      debugPrint('scanner close failed: $e');
    }
  }

  // ------------------------------------------------------------------ frames

  Future<void> _onFrame(CameraImage image) async {
    if (_busy || !_streaming) return;
    final now = DateTime.now();
    final last = _lastFrameAt;
    if (last != null && now.difference(last) < kFrameMinInterval) return;

    final scanner = _scanner;
    final camera = _camera;
    if (scanner == null || camera == null) return;

    _busy = true;
    _lastFrameAt = now;
    final session = _session;
    try {
      if (image.planes.isEmpty) return;
      final yPlane = image.planes.first;
      _publishBrightness(
        meanLuminance(
          yPlane.bytes,
          image.width,
          image.height,
          yPlane.bytesPerRow,
        ),
      );

      final rotation = InputImageRotationValue.fromRawValue(
        camera.description.sensorOrientation,
      );
      if (rotation == null) return;

      // NV21 requires all planes concatenated (Y + UV) into one buffer.
      // Passing only planes.first (Y only) gives ML Kit a truncated image
      // with no chroma data, so it cannot decode any barcode.
      final allBytes = _concatenatePlanes(image.planes);

      final input = InputImage.fromBytes(
        bytes: allBytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: yPlane.bytesPerRow,
        ),
      );

      // Barcode coordinates come back in the upright (rotated) image.
      final quarterTurn =
          rotation == InputImageRotation.rotation90deg ||
          rotation == InputImageRotation.rotation270deg;
      final uprightW = (quarterTurn ? image.height : image.width).toDouble();
      final uprightH = (quarterTurn ? image.width : image.height).toDouble();

      final mlKitTimer = Stopwatch()..start();
      final barcodes = await scanner.processImage(input);
      _recordFrameMillis(mlKitTimer.elapsedMilliseconds);
      if (session != _session || _detections.isClosed) return;
      _frameErrors = 0;

      final detected = <DetectedBarcode>[];
      for (final barcode in barcodes) {
        final format = _formatName(barcode.format);
        final raw = _rawOf(barcode);
        if (format == null || raw == null || raw.isEmpty) continue;
        final box = barcode.boundingBox;
        detected.add(
          DetectedBarcode(
            rawValue: raw,
            format: format,
            centerX: (box.center.dx / uprightW).clamp(0.0, 1.0),
            centerY: (box.center.dy / uprightH).clamp(0.0, 1.0),
            widthFraction: (box.width / uprightW).clamp(0.0, 1.0),
          ),
        );
      }

      final picked = pickCentermost(detected);
      if (picked != null && kLogRawBarcodes) {
        debugPrint(
          'SCAN raw: ${picked.rawValue.replaceAll('\u001D', '<GS>')} '
          '(${picked.format}, width ${picked.widthFraction.toStringAsFixed(2)})',
        );
      }
      _detections.add(picked);
    } catch (e) {
      // One bad frame must never kill the stream, but a camera that keeps
      // failing is reported so the UI can offer "Try again".
      debugPrint('Frame processing failed: $e');
      if (session == _session && ++_frameErrors > _maxFrameErrors) _fail(e);
    } finally {
      _busy = false;
    }
  }

  /// Keeps the last 30 ML Kit call durations (for the speed metrics).
  void _recordFrameMillis(int millis) {
    _recentFrameMillis.add(millis);
    if (_recentFrameMillis.length > 30) _recentFrameMillis.removeAt(0);
  }

  void _publishBrightness(double value) {
    _recentBrightness.add(value);
    if (_recentBrightness.length > _brightnessWindow) {
      _recentBrightness.removeAt(0);
    }
    final smoothed =
        _recentBrightness.reduce((a, b) => a + b) / _recentBrightness.length;
    if (!_brightness.isClosed) _brightness.add(smoothed);
  }

  String? _rawOf(Barcode barcode) {
    final value = barcode.rawValue;
    if (value != null) return value;
    final bytes = barcode.rawBytes;
    if (bytes == null) return null;
    return latin1.decode(bytes, allowInvalid: true);
  }

  String? _formatName(BarcodeFormat format) {
    switch (format) {
      case BarcodeFormat.code128:
        return 'code128';
      case BarcodeFormat.dataMatrix:
        return 'dataMatrix';
      case BarcodeFormat.qrCode:
        return 'qrCode';
      case BarcodeFormat.ean13:
        return 'ean13';
      case BarcodeFormat.ean8:
        return 'ean8';
      default:
        return null;
    }
  }

  /// Concatenates all image planes into a single byte buffer.
  ///
  /// The camera plugin delivers NV21 as separate [Plane] objects:
  ///   planes[0] = Y  (full-res luma)
  ///   planes[1] = UV (interleaved chroma, half-res)
  ///
  /// ML Kit's InputImage.fromBytes expects them as one contiguous buffer
  /// (Y bytes followed by UV bytes), exactly as the Android NV21 spec says.
  /// Passing only planes[0] gives ML Kit a truncated image with no colour
  /// information, which is why it would never find a barcode.
  static Uint8List _concatenatePlanes(List<Plane> planes) {
    final totalBytes = planes.fold<int>(0, (sum, p) => sum + p.bytes.length);
    final result = Uint8List(totalBytes);
    var offset = 0;
    for (final plane in planes) {
      result.setRange(offset, offset + plane.bytes.length, plane.bytes);
      offset += plane.bytes.length;
    }
    return result;
  }
}
