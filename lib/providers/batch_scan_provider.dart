// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:camera/camera.dart' show CameraController;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/batch_scan_item.dart';
import '../models/detected_barcode.dart';
import '../models/scan_record.dart';
import '../services/barcode_scanner_service.dart';
import '../services/consensus_buffer.dart';
import '../services/database_service.dart';
import '../services/gs1_parser_service.dart';
import '../services/zoom_advisor.dart';
import '../utils/barcode_format_label.dart';
import '../utils/constants.dart';
import '../utils/gs1_constants.dart';

/// States of the batch scan screen's camera. There is no per-scan state:
/// batch scanning never pauses for a result, it only stops when the camera
/// cannot run at all.
enum BatchScanStatus {
  initializing,
  scanning,
  noCamera,
  permissionDenied,
  error,
}

/// Continuous multi-scan mode: barcodes are read one after another without a
/// result sheet in between. Every read goes through the same 3-of-5 consensus
/// as the single scan; valid GS1 data is saved to the database immediately,
/// duplicates are skipped in-session, and the session list accumulates what
/// has been handled for the end-of-session summary.
///
/// Owns the same "helpful" state as [ScannerProvider]: auto-zoom for small
/// barcodes, the low-light warning, and transient messages.
class BatchScanProvider extends ChangeNotifier {
  BatchScanProvider({
    required DatabaseService db,
    required BarcodeDetectionSource source,
    Gs1ParserService parser = const Gs1ParserService(),
    Duration consensusTimeout = kConsensusTimeout,
    Duration lockoutRelease = const Duration(milliseconds: 1500),
  }) : _db = db,
       _source = source,
       _parser = parser,
       _consensusTimeout = consensusTimeout,
       _lockoutRelease = lockoutRelease;

  final DatabaseService _db;
  final BarcodeDetectionSource _source;
  final Gs1ParserService _parser;
  final Duration _consensusTimeout;
  final Duration _lockoutRelease;
  final ConsensusBuffer _buffer = ConsensusBuffer();
  final ZoomAdvisor _advisor = ZoomAdvisor();

  /// If no detection arrives for this long, the barcode moved away and the
  /// partially read value is dropped.
  static const _idleReset = Duration(seconds: 2);

  /// After the user turns the torch on and off, the low-light chip stays away
  /// for this long.
  static const _lowLightNagPause = Duration(seconds: 20);

  /// Called after a record has been written to the database.
  VoidCallback? onRecordSaved;

  final StreamController<String> _messages =
      StreamController<String>.broadcast();

  StreamSubscription<DetectedBarcode?>? _subscription;
  StreamSubscription<double>? _brightnessSub;
  StreamSubscription<Object>? _errorSub;
  Timer? _idleTimer;
  Timer? _readTimer;
  Timer? _lockTimer;
  Timer? _lowLightTimer;
  Timer? _nagPauseTimer;

  /// Items handled during the session, newest first.
  final List<BatchScanItem> _items = [];
  bool _disposed = false;

  /// Same-barcode lockout: after a consensus, the barcode that was just
  /// handled is probably still under the camera. Its detections are ignored
  /// (they never reach the consensus buffer) until a different barcode
  /// appears or it has been out of view for [_lockoutRelease].
  String? _lockedRaw;

  bool _externalOpen = false;

  BatchScanStatus _status = BatchScanStatus.initializing;
  bool _torchOn = false;
  bool _torchSupported = true;
  bool _permissionPermanent = false;
  bool _isZoomed = false;
  bool _barcodeTooSmall = false;
  bool _lowLight = false;
  bool _lowLightPaused = false;

  BatchScanStatus get status => _status;
  bool get torchOn => _torchOn;

  /// False once the device proved to have no usable flash.
  bool get torchSupported => _torchSupported;
  bool get permissionPermanentlyDenied => _permissionPermanent;

  /// Everything handled so far, newest first.
  List<BatchScanItem> get items => List.unmodifiable(_items);
  int get savedCount =>
      _items.where((i) => i.state == BatchItemState.saved).length;
  int get skippedCount => _items.length - savedCount;
  bool get isEmpty => _items.isEmpty;

  /// Short, transient messages for the UI (e.g. "Already scanned.").
  Stream<String> get messages => _messages.stream;

  /// Auto-zoom is currently applied.
  bool get isZoomed => _isZoomed;

  /// The latest barcode seen is smaller than [kMinBarcodeWidthFraction].
  bool get barcodeTooSmall => _barcodeTooSmall;

  /// The camera has seen a dark scene for a while and the torch is off.
  bool get lowLight => _lowLight;

  /// The live camera, or null while it is (re)starting or unavailable, so the
  /// UI never holds a controller that is about to be disposed.
  CameraController? get cameraController =>
      _status == BatchScanStatus.scanning ? _source.cameraController : null;

  bool get _listening => _status == BatchScanStatus.scanning && !_externalOpen;

  // ----------------------------------------------------------------- control

  Future<void> start() async {
    _isZoomed = false;
    _cancelSubscriptions();
    _torchOn = false;
    _permissionPermanent = false;
    _lowLight = false;
    _lowLightTimer?.cancel();
    _lowLightTimer = null;
    _setStatus(BatchScanStatus.initializing);

    try {
      await _source.start();
      if (_disposed) return;
      _subscription = _source.detections.listen(_onDetection);
      _brightnessSub = _source.brightness.listen(_onBrightness);
      _errorSub = _source.errors.listen(_onSourceError);
      _advisor.canZoom = _source.supportsZoom;
      _setStatus(BatchScanStatus.scanning);
    } on CameraUnavailableException {
      _setStatus(BatchScanStatus.noCamera);
    } on CameraPermissionDeniedException catch (e) {
      _permissionPermanent = e.permanent;
      _setStatus(BatchScanStatus.permissionDenied);
    } catch (e) {
      debugPrint('Camera start failed: $e');
      _setStatus(BatchScanStatus.error);
    }
  }

  /// Releases the camera when the batch screen closes or the user finishes.
  /// Silent (no notification) because the screen is right behind it.
  Future<void> stop() async {
    _releaseLock();
    _readTimer?.cancel();
    _readTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _buffer.reset();
    _isZoomed = false;
    _lowLightTimer?.cancel();
    _lowLightTimer = null;
    _nagPauseTimer?.cancel();
    _nagPauseTimer = null;
    _lowLight = false;
    _lowLightPaused = false;
    _externalOpen = false;
    _cancelSubscriptions();
    _torchOn = false;
    _status = BatchScanStatus.initializing;
    await _source.dispose();
  }

  /// Toggles the torch. False when this device has no usable flash (the
  /// caller shows a message) or the request failed.
  Future<bool> toggleTorch() async {
    if (!_torchSupported) return false;
    final target = !_torchOn;
    final ok = await _source.setTorch(target);
    if (_disposed) return ok;
    if (!ok) {
      _torchSupported = false;
      notifyListeners();
      return false;
    }
    _torchOn = target;
    _onTorchChanged(target);
    notifyListeners();
    return true;
  }

  void _onTorchChanged(bool on) {
    if (on) {
      // The chip's job is done.
      _lowLightTimer?.cancel();
      _lowLightTimer = null;
      _lowLight = false;
    } else {
      // Turned off again: do not nag straight away.
      _lowLightPaused = true;
      _nagPauseTimer?.cancel();
      _nagPauseTimer = Timer(_lowLightNagPause, () => _lowLightPaused = false);
    }
  }

  /// Another screen (the session list, manual entry) is about to cover the
  /// camera.
  Future<void> pauseForExternalScreen() async {
    _externalOpen = true;
    _readTimer?.cancel();
    _idleTimer?.cancel();
    await _source.pause();
  }

  Future<void> resumeAfterExternalScreen() async {
    _externalOpen = false;
    if (_disposed || !_listening) return;
    await _source.resume();
  }

  Future<void> onAppPaused() async {
    _readTimer?.cancel();
    _idleTimer?.cancel();
    await _source.pause();
  }

  Future<void> onAppResumed() async {
    if (_status == BatchScanStatus.permissionDenied) {
      // Back from Settings: if the user allowed the camera, just start. Never
      // prompt here (no loops).
      if (await _source.isCameraPermissionGranted() && !_disposed) {
        await start();
      }
      return;
    }
    if (!_listening) return;
    _resetZoom();
    await _source.resume();
  }

  // ------------------------------------------------------------- detections

  void _onDetection(DetectedBarcode? detection) {
    if (!_listening) return;

    // A frame with no barcode breaks the zoom streaks; the idle timer handles
    // "the barcode moved away".
    if (detection == null) {
      _advisor.onNoDetection();
      return;
    }

    final locked = _lockedRaw;
    if (locked != null) {
      if (detection.rawValue == locked) {
        // Still the same barcode: restart the "out of view" clock and ignore.
        _lockTimer?.cancel();
        _lockTimer = Timer(_lockoutRelease, _releaseLock);
        return;
      }
      _releaseLock(); // a different barcode
    }

    _adviseZoom(detection);

    final consensus = _buffer.add(detection.rawValue, detection.format);
    _readTimer ??= Timer(_consensusTimeout, _onReadTimeout);
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleReset, _onIdle);

    if (consensus != null) _handle(consensus);
  }

  /// Small barcode: tell the user to move closer, then zoom in once.
  void _adviseZoom(DetectedBarcode detection) {
    _advisor.canZoom = _source.supportsZoom;
    final advice = _advisor.onDetection(detection.widthFraction);
    var changed = false;

    if (advice == ZoomAdvice.zoomIn && _source.supportsZoom && !_isZoomed) {
      _isZoomed = true;
      unawaited(_source.setZoom(kAutoZoomLevel));
      changed = true;
    } else if (advice == ZoomAdvice.zoomOut && _isZoomed) {
      _isZoomed = false;
      unawaited(_source.setZoom(1.0));
      changed = true;
    }

    final small = _advisor.isSmall;
    if (small != _barcodeTooSmall) {
      _barcodeTooSmall = small;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _resetZoom() {
    _advisor.reset();
    _barcodeTooSmall = false;
    if (_isZoomed) {
      _isZoomed = false;
      unawaited(_source.setZoom(1.0));
    }
  }

  void _releaseLock() {
    _lockTimer?.cancel();
    _lockTimer = null;
    _lockedRaw = null;
  }

  void _onIdle() {
    if (!_listening) return;
    _readTimer?.cancel();
    _readTimer = null;
    _buffer.reset();
  }

  /// Ten seconds of barcode-in-view without agreement: tell the user and
  /// start the read over. The camera never stops in batch mode.
  void _onReadTimeout() {
    _readTimer = null;
    if (!_listening) return;
    _buffer.reset();
    if (!_messages.isClosed) {
      _messages.add('Could not read it · Hold steady and try again');
    }
  }

  // ------------------------------------------------------------ consensus

  /// A barcode read reliably enough. Locks it out (it is still under the
  /// camera), then works out where it belongs — the await happens off the
  /// detection path so frames keep flowing.
  void _handle(ConsensusResult consensus) {
    _cancelReadTimers();
    _buffer.reset();

    // Set before any await, so a second consensus cannot double-handle.
    _lockedRaw = consensus.raw;
    _lockTimer = Timer(_lockoutRelease, _releaseLock);

    unawaited(_process(consensus));
  }

  void _cancelReadTimers() {
    _readTimer?.cancel();
    _readTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  Future<void> _process(ConsensusResult consensus) async {
    final raw = consensus.raw;

    // Already handled (and kept) in this session: skip and say so.
    if (_items.any(
      (i) => i.state == BatchItemState.saved && i.record.rawBarcode == raw,
    )) {
      if (!_messages.isClosed) _messages.add('Already scanned · Skipped');
      return;
    }

    final isRetail = consensus.format == 'ean13' || consensus.format == 'ean8';
    final parse = _parser.parse(
      raw,
      barcodeFormat: isRetail
          ? (consensus.format == 'ean13' ? kFormatEan13 : kFormatEan8)
          : null,
      // Consensus was reached, so internal batch spaces are consistent.
      preserveBatchSpaces: consensus.reachedConsensus,
    );

    final record = ScanRecord.create(
      rawBarcode: raw,
      barcodeFormat: barcodeFormatLabel(consensus.format, parse.isGs1),
      batchNumber: parse.batchNumber,
      gtin: parse.gtin,
      expiryDate: parse.expiryYymmdd,
      serialNumber: parse.serialNumber,
      confidenceScore: consensus.confidence,
      isValid: parse.isValid,
    );

    // Nothing GS1-like in it at all (a plain QR, a URL, ...): skip it. It is
    // listed in the session so the item count stays honest.
    final hasGs1Fields =
        parse.batchNumber != null ||
        parse.gtin != null ||
        parse.expiryYymmdd != null ||
        parse.serialNumber != null;
    if (!hasGs1Fields) {
      _addItem(BatchScanItem(record, state: BatchItemState.unrecognised));
      if (!_messages.isClosed) _messages.add('Unrecognised barcode · Skipped');
      return;
    }

    // Parsed but flagged by the parser (bad expiry, stray characters, ...):
    // still saved — the history shows it as an alert.
    try {
      await _db.insert(record);
      if (_disposed) return; // the session ended while writing; row is saved
      onRecordSaved?.call();
      _addItem(BatchScanItem(record, state: BatchItemState.saved));
      unawaited(_feedback());
      if (!parse.isValid && !_messages.isClosed) {
        _messages.add('Saved with warnings');
      }
    } catch (e, st) {
      debugPrint('Saving scan failed: $e\n$st');
      if (_disposed) return;
      _addItem(BatchScanItem(record, state: BatchItemState.saveFailed));
      if (!_messages.isClosed) _messages.add('Could not save this scan');
    }
  }

  void _addItem(BatchScanItem item) {
    _items.insert(0, item);
    notifyListeners();
  }

  Future<void> _feedback() async {
    try {
      await HapticFeedback.mediumImpact();
      await SystemSound.play(SystemSoundType.click);
    } catch (_) {
      // Feedback is a nicety; never let it affect scanning.
    }
  }

  // ------------------------------------------------------------ mock fallback

  /// The device has no camera (kMockScanFallback): one mock barcode per
  /// session, going through exactly the same consensus/process flow.
  void mockScanOnce() {
    if (_status != BatchScanStatus.scanning) return;
    _handle(
      ConsensusResult(
        raw: '(01)08901234567890(17)261231(10)BN2024X981',
        format: 'dataMatrix',
        matches: kConsensusWindow,
        confidence: 1.0,
        reachedConsensus: true,
      ),
    );
  }

  // ------------------------------------------------------------ light

  /// Smoothed frame brightness. Dark for [kLowLightHoldTime] with the torch
  /// off raises the low-light warning; it clears as soon as it brightens.
  void _onBrightness(double value) {
    if (value >= kLowLightLuma) {
      _lowLightTimer?.cancel();
      _lowLightTimer = null;
      if (_lowLight) {
        _lowLight = false;
        notifyListeners();
      }
      return;
    }
    if (_torchOn || _lowLightPaused || _lowLight || _lowLightTimer != null) {
      return;
    }
    _lowLightTimer = Timer(kLowLightHoldTime, () {
      _lowLightTimer = null;
      if (_torchOn || _lowLightPaused) return;
      _lowLight = true;
      notifyListeners();
    });
  }

  // -------------------------------------------------------- source errors

  /// The camera failed at runtime (disconnected, or the stream kept throwing).
  void _onSourceError(Object error) {
    debugPrint('Batch scanner source error: $error');
    if (_status == BatchScanStatus.noCamera ||
        _status == BatchScanStatus.permissionDenied ||
        _status == BatchScanStatus.error) {
      return;
    }
    _cancelReadTimers();
    _setStatus(BatchScanStatus.error);
  }

  // ------------------------------------------------------------- helpers

  void _cancelSubscriptions() {
    unawaited(_subscription?.cancel());
    unawaited(_brightnessSub?.cancel());
    unawaited(_errorSub?.cancel());
    _subscription = null;
    _brightnessSub = null;
    _errorSub = null;
  }

  void _setStatus(BatchScanStatus status) {
    _status = status;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelReadTimers();
    for (final timer in [_lockTimer, _lowLightTimer, _nagPauseTimer]) {
      timer?.cancel();
    }
    unawaited(_subscription?.cancel());
    unawaited(_brightnessSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_messages.close());
    unawaited(_source.dispose());
    super.dispose();
  }
}
