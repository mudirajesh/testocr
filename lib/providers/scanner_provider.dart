// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show CameraController;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:path_provider/path_provider.dart';

import '../models/detected_barcode.dart';
import '../models/gs1_parse_result.dart';
import '../models/scan_record.dart';
import '../services/barcode_scanner_service.dart';
import '../services/consensus_buffer.dart';
import '../services/database_service.dart';
import '../services/gs1_parser_service.dart';
import '../services/medicine_lookup_service.dart';
import '../services/ocr_service.dart';
import '../services/zoom_advisor.dart';
import '../utils/barcode_format_label.dart';
import '../utils/barcode_formats.dart';
import '../utils/constants.dart';
import '../utils/gs1_constants.dart';
import '../utils/scan_metrics.dart';

enum ScannerStatus {
  initializing,
  scanning,
  processing,

  /// Consensus reached, the record is valid and has been saved.
  success,

  /// The 10-second timeout hit without consensus. Nothing is saved.
  lowConfidence,

  /// Consensus reached but the parse is invalid (or the auto-save failed).
  /// Nothing is saved until the user chooses Save Anyway.
  needsReview,
  noCamera,
  permissionDenied,
  error,
}

/// Drives a scan attempt: camera detections -> 3-of-5 consensus -> duplicate
/// check -> parse -> (auto-)save. Valid scans are saved before the result
/// sheet opens; questionable ones wait for the user's decision.
///
/// It also owns the "helpful" state of the Scan screen: auto-zoom for small
/// barcodes, the low-light warning, the "having trouble?" timer and the
/// transient messages.
class ScannerProvider extends ChangeNotifier {
  ScannerProvider({
    required DatabaseService db,
    required BarcodeDetectionSource source,
    Gs1ParserService parser = const Gs1ParserService(),
    MedicineLookupService medicineLookup = const MedicineLookupService(),
    OcrService ocrService = const OcrService(),
    Duration consensusTimeout = kConsensusTimeout,
    Duration lockoutRelease = const Duration(milliseconds: 1500),
  }) : _db = db,
       _source = source,
       _parser = parser,
       _medicineLookup = medicineLookup,
       _ocrService = ocrService,
       _consensusTimeout = consensusTimeout,
       _lockoutRelease = lockoutRelease;

  final DatabaseService _db;
  final BarcodeDetectionSource _source;
  final Gs1ParserService _parser;
  final MedicineLookupService _medicineLookup;
  final OcrService _ocrService;
  final Duration _consensusTimeout;
  final Duration _lockoutRelease;
  final ConsensusBuffer _buffer = ConsensusBuffer();
  final ZoomAdvisor _advisor = ZoomAdvisor();

  /// If no detection arrives for this long while processing, the user moved
  /// away and the attempt starts over.
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
  Timer? _timeoutTimer;
  Timer? _idleTimer;
  Timer? _lockTimer;
  Timer? _troubleTimer;
  Timer? _lowLightTimer;
  Timer? _nagPauseTimer;
  Stopwatch? _attemptClock;

  /// Runs from the moment scanning (re)starts until the first detection.
  Stopwatch? _sinceScanStart;
  int? _firstDetectionMs;
  ScanMetrics? _lastMetrics;
  bool _disposed = false;

  /// Bumped whenever the current attempt is abandoned, so work that was
  /// awaiting (duplicate check, save) can tell it is stale.
  int _attemptId = 0;

  /// True from the moment a result is picked until rescan(); late frames that
  /// are still in the stream must not start a new attempt.
  bool _resolving = false;

  /// Same-barcode lockout: after rescan() the barcode that was just handled is
  /// probably still under the camera. Its detections are ignored (they never
  /// reach the consensus buffer) until a different barcode appears or it has
  /// been out of view for [_lockoutRelease].
  String? _lockedRaw;

  /// A result sheet or another screen (manual entry) is on top, so the camera
  /// must stay paused.
  bool _sheetOpen = false;
  bool _externalOpen = false;

  /// The camera reported a runtime failure; only a full start() recovers it.
  bool _sourceFailed = false;

  ScannerStatus _status = ScannerStatus.initializing;
  bool _torchOn = false;
  bool _torchSupported = true;
  bool _permissionPermanent = false;
  bool _isZoomed = false;
  bool _barcodeTooSmall = false;
  bool _lowLight = false;
  bool _lowLightPaused = false;
  bool _showTroubleHint = false;
  ScanRecord? _result;
  Gs1ParseResult? _parseResult;
  String? _errorMessage;
  bool _isSaved = false;
  bool _saveFailed = false;
  Future<bool>? _saving;

  ScannerStatus get status => _status;
  bool get torchOn => _torchOn;

  /// False once the device proved to have no usable flash.
  bool get torchSupported => _torchSupported;
  bool get permissionPermanentlyDenied => _permissionPermanent;
  ScanRecord? get result => _result;
  Gs1ParseResult? get parseResult => _parseResult;
  String? get errorMessage => _errorMessage;

  /// Timing of the most recent accepted (or timed-out) scan.
  ScanMetrics? get lastMetrics => _lastMetrics;

  /// Short, transient messages for the UI (e.g. "Already scanned.").
  Stream<String> get messages => _messages.stream;

  /// Auto-zoom is currently applied.
  bool get isZoomed => _isZoomed;

  /// The latest barcode seen is smaller than [kMinBarcodeWidthFraction].
  bool get barcodeTooSmall => _barcodeTooSmall;

  /// The camera has seen a dark scene for a while and the torch is off.
  bool get lowLight => _lowLight;

  /// Nothing was detected for [kNoBarcodeHintAfter] while scanning.
  bool get showTroubleHint => _showTroubleHint;

  /// The current result is stored in the database.
  bool get isSaved => _isSaved;

  /// The last save attempt threw.
  bool get saveFailed => _saveFailed;

  /// Parser errors and warnings as readable lines, plus the consensus note
  /// when the scan timed out.
  List<String> get issues {
    final lines = <String>[];
    final record = _result;
    if (_status == ScannerStatus.lowConfidence && record != null) {
      final agreed = ((record.confidenceScore ?? 0) * kConsensusWindow).round();
      lines.add(
        'Low confidence: only $agreed of $kConsensusWindow frames agreed',
      );
    }
    final parse = _parseResult;
    if (parse != null) {
      lines
        ..addAll(parse.errors)
        ..addAll(parse.warnings);
    }
    return lines;
  }

  /// The live camera, or null while it is (re)starting or unavailable, so the
  /// UI never holds a controller that is about to be disposed.
  CameraController? get cameraController {
    switch (_status) {
      case ScannerStatus.scanning:
      case ScannerStatus.processing:
      case ScannerStatus.success:
      case ScannerStatus.lowConfidence:
      case ScannerStatus.needsReview:
        return _source.cameraController;
      case ScannerStatus.initializing:
      case ScannerStatus.noCamera:
      case ScannerStatus.permissionDenied:
      case ScannerStatus.error:
        return null;
    }
  }

  bool get _canRun => !_sheetOpen && !_externalOpen;

  bool get _isListening =>
      !_resolving &&
      (_status == ScannerStatus.scanning ||
          _status == ScannerStatus.processing);

  // ----------------------------------------------------------------- control

  Future<void> start() async {
    _resetAttempt();
    _isZoomed = false;
    _cancelSubscriptions();
    _errorMessage = null;
    _torchOn = false;
    _permissionPermanent = false;
    _sourceFailed = false;
    _lowLight = false;
    _lowLightTimer?.cancel();
    _lowLightTimer = null;
    _setStatus(ScannerStatus.initializing);

    try {
      await _source.start();
      if (_disposed) return;
      _subscription = _source.detections.listen(_onDetection);
      _brightnessSub = _source.brightness.listen(_onBrightness);
      _errorSub = _source.errors.listen(_onSourceError);
      _advisor.canZoom = _source.supportsZoom;
      _setStatus(ScannerStatus.scanning);
      _restartTroubleTimer();
      _startScanClock();
    } on CameraUnavailableException {
      _setStatus(ScannerStatus.noCamera);
    } on CameraPermissionDeniedException catch (e) {
      _permissionPermanent = e.permanent;
      _setStatus(ScannerStatus.permissionDenied);
    } catch (e) {
      debugPrint('Camera start failed: $e');
      _errorMessage = e.toString();
      _setStatus(ScannerStatus.error);
    }
  }

  /// Releases the camera when the scan screen closes. Silent (no
  /// notification) because it runs while the screen is being torn down.
  Future<void> stop() async {
    _resetAttempt();
    _isZoomed = false;
    _lowLightTimer?.cancel();
    _lowLightTimer = null;
    _nagPauseTimer?.cancel();
    _nagPauseTimer = null;
    _lowLight = false;
    _lowLightPaused = false;
    _sheetOpen = false;
    _externalOpen = false;
    _cancelSubscriptions();
    _torchOn = false;
    _status = ScannerStatus.initializing;
    await _source.dispose();
  }

  Future<void> rescan() async {
    _sheetOpen = false;
    final needsRestart =
        _sourceFailed ||
        _status == ScannerStatus.error ||
        _status == ScannerStatus.noCamera ||
        _status == ScannerStatus.permissionDenied;
    if (needsRestart) return start();

    // Lock out the barcode we just handled. A timed-out, unsaved read is not
    // locked: the user pressing Rescan wants to try that barcode again.
    final handled = _result;
    final lock =
        handled != null &&
        (_isSaved ||
            _status == ScannerStatus.success ||
            _status == ScannerStatus.needsReview);
    _resetAttempt();
    _resetZoom();
    if (lock) {
      _lockedRaw = handled.rawBarcode;
      _lockTimer = Timer(_lockoutRelease, _releaseLock);
    }

    await _source.resume();
    if (_disposed) return;
    _setStatus(ScannerStatus.scanning);
    _restartTroubleTimer();
    _startScanClock();
  }

  /// Manually triggers immediate capture and analysis of the current pack.
  Future<void> captureManual() async {
    if (_disposed || !_isListening || _resolving) return;
    _cancelTimers();
    _resolving = true;
    await _source.pause();

    String? photoPath;
    try {
      final rawPath = await _source.takePicture();
      if (rawPath != null) {
        photoPath = await _persistPhoto(rawPath);
      }
    } catch (e) {
      debugPrint('Manual capture picture failed: $e');
    }

    if (photoPath != null) {
      await processImportedImage(photoPath);
    } else {
      _resolving = false;
      await _source.resume();
      if (_disposed) return;
      _setStatus(ScannerStatus.scanning);
    }
  }

  /// Processes an image from camera photo capture or image picker gallery.
  /// 1. Runs barcode scanning.
  /// 2. If no barcode or missing batch, runs fallback OCR.
  /// 3. Looks up medicine in medicine database.
  Future<void> processImportedImage(String imagePath) async {
    _cancelTimers();
    _resolving = true;
    await _source.pause();
    _setStatus(ScannerStatus.processing);

    final persistentPath = await _persistPhoto(imagePath);

    // 1. Try Barcode scanning first. Only formats that can carry a batch
    // number are enabled, so an EAN product code is never chosen over a lot.
    final scanner = BarcodeScanner(formats: kMlKitScanFormats);

    List<Barcode> barcodes = [];
    try {
      barcodes = await scanner.processImage(
        InputImage.fromFilePath(persistentPath),
      );
    } catch (e) {
      debugPrint('Barcode scanner on file failed: $e');
    } finally {
      await scanner.close();
    }

    final detected = <DetectedBarcode>[];
    for (final barcode in barcodes) {
      final format = mlKitFormatName(barcode.format);
      final raw = barcode.rawValue;
      if (format == null || raw == null || raw.isEmpty) continue;
      detected.add(
        DetectedBarcode(
          rawValue: raw,
          format: format,
          centerX: 0.5,
          centerY: 0.5,
        ),
      );
    }
    final picked = pickBatchBarcode(detected);

    if (picked != null) {
      final raw = picked.rawValue;
      final fmt = picked.format;
      final consensus = ConsensusResult(
        raw: raw,
        format: fmt,
        matches: 1,
        confidence: 1.0,
        reachedConsensus: true,
      );

      final parse = _parser.parse(raw, barcodeFormat: fmt);
      String? ocrBatch;
      String? ocrExpiry;
      String? ocrMedicine;
      String? ocrStrength;
      bool recoveredOcr = false;

      if (parse.batchNumber == null) {
        final ocr = await _ocrService.processImage(persistentPath);
        if (ocr.hasBatch || ocr.hasMedicine) {
          ocrBatch = ocr.batchNumber;
          ocrExpiry = ocr.expiryDate;
          ocrMedicine = ocr.medicineName;
          ocrStrength = ocr.strength;
          recoveredOcr = true;
        }
      }

      final record = _pick(
        consensus,
        imagePath: persistentPath,
        ocrBatch: ocrBatch,
        ocrExpiry: ocrExpiry,
        ocrMedicine: ocrMedicine,
        ocrStrength: ocrStrength,
        isOcr: recoveredOcr,
      );
      await _completeAccepted(record);
      return;
    }

    // 2. Barcode not detected -> Fallback OCR!
    debugPrint('No barcode detected. Running fallback OCR...');
    final ocr = await _ocrService.processImage(persistentPath);

    if (ocr.hasBatch || ocr.hasMedicine) {
      final record = ScanRecord.create(
        rawBarcode: ocr.rawText.isNotEmpty ? ocr.rawText : 'OCR Capture',
        barcodeFormat: kOcrBarcodeFormat,
        batchNumber: ocr.batchNumber,
        expiryDate: ocr.expiryDate,
        medicineName: ocr.medicineName,
        strength: ocr.strength,
        confidenceScore: 0.9,
        isValid: ocr.hasBatch,
        imagePath: persistentPath,
        isOcr: true,
      );
      _result = record;
      _setStatus(record.isValid ? ScannerStatus.success : ScannerStatus.needsReview);
      await saveCurrent();
    } else {
      if (!_messages.isClosed) {
        _messages.add('No barcode or medicine text found. Check packaging.');
      }
      _buffer.reset();
      _resolving = false;
      await _source.resume();
      if (_disposed) return;
      _setStatus(ScannerStatus.scanning);
    }
  }

  /// Called when user confirms or verifies the medicine identity.
  Future<void> confirmMedicineVerification(bool verified) async {
    final current = _result;
    if (current == null) return;
    final updated = current.copyWith(verifiedByUser: verified);
    _result = updated;
    notifyListeners();
    try {
      await _db.insert(updated);
    } catch (e) {
      debugPrint('Failed to update verified medicine record: $e');
    }
  }

  /// Saves the current result. Idempotent: an already saved result is not
  /// inserted twice. Never throws; returns false and sets [saveFailed] when
  /// the write fails. The record's isValid flag is never changed.
  Future<bool> saveCurrent() {
    final record = _result;
    if (record == null) return Future.value(false);
    if (_isSaved) return Future.value(true);
    return _saving ??= _save(record).whenComplete(() => _saving = null);
  }

  Future<bool> _save(ScanRecord record) async {
    try {
      await _db.insert(record);
      if (_result != record) return true; // reset while writing; row is saved
      _isSaved = true;
      _saveFailed = false;
      notifyListeners();
      onRecordSaved?.call();
      return true;
    } catch (e, st) {
      debugPrint('Saving scan failed: $e\n$st');
      if (_result == record) {
        _saveFailed = true;
        notifyListeners();
      }
      return false;
    }
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

  /// The result sheet opened or closed; while it is open the camera must not
  /// run and the "having trouble" timer must not tick.
  void setSheetOpen(bool open) {
    _sheetOpen = open;
    if (open) _clearTroubleHint();
  }

  /// Another screen (manual entry) is about to cover the camera.
  Future<void> pauseForExternalScreen() async {
    _externalOpen = true;
    _suspendTimers();
    await _source.pause();
  }

  Future<void> resumeAfterExternalScreen() async {
    _externalOpen = false;
    if (_disposed || !_isListening || !_canRun) return;
    await _source.resume();
    _resumeTimers();
  }

  Future<void> onAppPaused() async {
    // The consensus buffer is kept; only the timers stop, so a stale timeout
    // cannot fire in the background.
    _suspendTimers();
    await _source.pause();
  }

  Future<void> onAppResumed() async {
    if (_status == ScannerStatus.permissionDenied) {
      // Back from Settings: if the user allowed the camera, just start. Never
      // prompt here (no loops).
      if (await _source.isCameraPermissionGranted() && !_disposed) {
        await start();
      }
      return;
    }
    if (!_isListening || !_canRun) return;
    _resetZoom();
    await _source.resume();
    _resumeTimers();
  }

  /// Hides the "having trouble" card until the next 15-second period.
  void dismissTroubleHint() {
    _showTroubleHint = false;
    _restartTroubleTimer();
    notifyListeners();
  }

  // ------------------------------------------------------------- detections

  void _onDetection(DetectedBarcode? detection) {
    if (!_isListening) return;

    // A frame with no barcode does not clear the buffer; the idle timer
    // handles "the user moved away".
    if (detection == null) {
      _advisor.onNoDetection();
      return;
    }

    // Any barcode in view means the user is not stuck.
    _clearTroubleHint();
    _restartTroubleTimer();

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

    if (_status == ScannerStatus.scanning) {
      _firstDetectionMs = _sinceScanStart?.elapsedMilliseconds;
      _attemptClock = Stopwatch()..start();
      _timeoutTimer = Timer(_consensusTimeout, _onTimeout);
      _setStatus(ScannerStatus.processing);
    }
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleReset, _onIdle);

    if (consensus != null) _accept(consensus);
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
    if (_status != ScannerStatus.processing || _resolving) return;
    _cancelTimers();
    _buffer.reset();
    _attemptClock = null;
    _setStatus(ScannerStatus.scanning);
    _restartTroubleTimer();
  }

  void _onTimeout() {
    if (_status != ScannerStatus.processing || _resolving) return;
    final best = _buffer.bestSoFar();
    _cancelTimers();
    if (best == null) {
      _buffer.reset();
      _setStatus(ScannerStatus.scanning);
      _restartTroubleTimer();
      return;
    }
    _resolving = true;
    unawaited(_source.pause());
    unawaited(_resolveTimedOut(best, _attemptId));
  }

  void _accept(ConsensusResult consensus) {
    final elapsed = _attemptClock?.elapsedMilliseconds;
    _cancelTimers();
    _resolving = true;
    unawaited(_source.pause());
    unawaited(_resolveAccepted(consensus, _attemptId, elapsed));
  }

  Future<void> _resolveAccepted(
    ConsensusResult consensus,
    int attempt,
    int? elapsed,
  ) async {
    if (await _isDuplicate(consensus.raw)) {
      if (_isStale(attempt)) return;
      await _restartAfterDuplicate(consensus.raw);
      return;
    }
    if (_isStale(attempt)) return;

    // Capture a still picture of the pack when barcode is recognized.
    String? photoPath;
    try {
      final rawPath = await _source.takePicture();
      if (rawPath != null) {
        photoPath = await _persistPhoto(rawPath);
      }
    } catch (e) {
      debugPrint('Auto-capture photo failed: $e');
    }

    if (_isStale(attempt)) return;

    // Check if barcode gave batch number. If not, trigger Fallback OCR!
    String? ocrBatch;
    String? ocrExpiry;
    String? ocrMedicine;
    String? ocrStrength;
    bool recoveredByOcr = false;

    if (photoPath != null) {
      final preliminary = _parser.parse(consensus.raw);
      if (preliminary.batchNumber == null) {
        try {
          final ocr = await _ocrService.processImage(photoPath);
          if (ocr.hasBatch || ocr.hasMedicine) {
            ocrBatch = ocr.batchNumber;
            ocrExpiry = ocr.expiryDate;
            ocrMedicine = ocr.medicineName;
            ocrStrength = ocr.strength;
            recoveredByOcr = true;
          }
        } catch (e) {
          debugPrint('Fallback OCR on photo failed: $e');
        }
      }
    }

    if (_isStale(attempt)) return;
    final record = _pick(
      consensus,
      imagePath: photoPath,
      ocrBatch: ocrBatch,
      ocrExpiry: ocrExpiry,
      ocrMedicine: ocrMedicine,
      ocrStrength: ocrStrength,
      isOcr: recoveredByOcr,
    );
    _recordMetrics(elapsed);
    await _completeAccepted(record);
  }

  Future<void> _resolveTimedOut(ConsensusResult best, int attempt) async {
    final elapsed = _attemptClock?.elapsedMilliseconds;
    if (await _isDuplicate(best.raw)) {
      if (_isStale(attempt)) return;
      await _restartAfterDuplicate(best.raw);
      return;
    }
    if (_isStale(attempt)) return;

    String? photoPath;
    try {
      final rawPath = await _source.takePicture();
      if (rawPath != null) {
        photoPath = await _persistPhoto(rawPath);
      }
    } catch (e) {
      debugPrint('Photo capture on timeout failed: $e');
    }

    if (_isStale(attempt)) return;
    _pick(best, imagePath: photoPath);
    _recordMetrics(elapsed);
    _setStatus(ScannerStatus.lowConfidence); // never auto-saved
  }

  /// Copies captured camera image to permanent app documents storage.
  Future<String> _persistPhoto(String tempPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final scansDir = Directory('${appDir.path}/scans');
      if (!await scansDir.exists()) {
        await scansDir.create(recursive: true);
      }
      final destPath =
          '${scansDir.path}/scan_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(tempPath).copy(destPath);
      return destPath;
    } catch (_) {
      return tempPath;
    }
  }

  void _startScanClock() {
    _sinceScanStart = Stopwatch()..start();
    _firstDetectionMs = null;
  }

  /// Remembers (and, in debug/profile builds, logs) how long this scan took.
  void _recordMetrics(int? consensusMs) {
    final metrics = ScanMetrics(
      firstDetectionMs: _firstDetectionMs ?? 0,
      consensusMs: consensusMs ?? 0,
      averageFrameMs: _source.averageFrameMillis,
    );
    _lastMetrics = metrics;
    if (scanMetricsLoggingEnabled()) {
      debugPrint(metrics.format());
    }
  }

  bool _isStale(int attempt) => _disposed || attempt != _attemptId;

  /// The same raw value saved within [kDedupWindow] is "Already scanned.".
  /// A database failure here must not block scanning, so it counts as "no".
  Future<bool> _isDuplicate(String raw) async {
    try {
      return await _db.existsRecentRaw(raw, kDedupWindow);
    } catch (e) {
      debugPrint('Duplicate check failed, continuing: $e');
      return false;
    }
  }

  Future<void> _restartAfterDuplicate(String raw) async {
    if (!_messages.isClosed) _messages.add('Already scanned.');
    _buffer.reset();
    _attemptClock = null;
    _resolving = false;
    // The barcode is still in front of the camera: ignore it until it leaves.
    _releaseLock();
    _lockedRaw = raw;
    _lockTimer = Timer(_lockoutRelease, _releaseLock);

    await _source.resume();
    if (_disposed) return;
    _setStatus(ScannerStatus.scanning);
    _restartTroubleTimer();
  }

  /// Valid scans are saved BEFORE the sheet opens; anything else waits for
  /// the user. A failed auto-save is also routed to review so the sheet can
  /// offer "Retry Save".
  Future<void> _completeAccepted(ScanRecord record) async {
    if (!record.isValid) {
      _setStatus(ScannerStatus.needsReview);
      return;
    }
    final saved = await saveCurrent();
    if (_disposed || _result != record) return; // reset while saving
    if (saved) {
      _setStatus(ScannerStatus.success);
      unawaited(_feedback());
    } else {
      _setStatus(ScannerStatus.needsReview);
    }
  }

  /// Parses the picked value and stores it as the (unsaved) current result.
  ScanRecord _pick(
    ConsensusResult picked, {
    String? imagePath,
    String? ocrBatch,
    String? ocrExpiry,
    String? ocrMedicine,
    String? ocrStrength,
    bool isOcr = false,
  }) {
    final reached = picked.reachedConsensus;
    final isRetail = picked.format == 'ean13' || picked.format == 'ean8';

    // With 3+ agreeing frames internal batch spaces are consistently present,
    // so they are kept; on a timeout they are stripped.
    final parse = _parser.parse(
      picked.raw,
      barcodeFormat: isRetail
          ? (picked.format == 'ean13' ? kFormatEan13 : kFormatEan8)
          : picked.format,
      preserveBatchSpaces: reached,
    );

    // Medicine lookup from GTIN or raw barcode
    final matched = _medicineLookup.lookup(
      gtin: parse.gtin,
      rawBarcode: picked.raw,
    );

    final batch = parse.batchNumber ?? ocrBatch;
    final expiry = parse.expiryYymmdd ?? ocrExpiry;
    final medName = matched?.name ?? ocrMedicine;
    final medStrength = matched?.strength ?? ocrStrength;

    final record = ScanRecord.create(
      rawBarcode: picked.raw,
      barcodeFormat: _formatLabel(picked.format, parse.isGs1),
      batchNumber: batch,
      gtin: parse.gtin,
      expiryDate: expiry,
      serialNumber: parse.serialNumber,
      confidenceScore: picked.confidence,
      isValid: reached && batch != null && batch.isNotEmpty,
      imagePath: imagePath,
      medicineName: medName,
      strength: medStrength,
      isOcr: isOcr || (parse.batchNumber == null && ocrBatch != null),
    );
    _parseResult = parse;
    _result = record;
    _isSaved = false;
    _saveFailed = false;
    return record;
  }

  String _formatLabel(String format, bool isGs1) =>
      barcodeFormatLabel(format, isGs1);

  Future<void> _feedback() async {
    try {
      await HapticFeedback.mediumImpact();
      await SystemSound.play(SystemSoundType.click);
    } catch (_) {
      // Feedback is a nicety; never let it affect scanning.
    }
  }

  // ------------------------------------------------------- light and trouble

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

  void _restartTroubleTimer() {
    _troubleTimer?.cancel();
    _troubleTimer = Timer(kNoBarcodeHintAfter, _onTroubleTimeout);
  }

  void _onTroubleTimeout() {
    _troubleTimer = null;
    if (_status == ScannerStatus.scanning && _canRun && !_resolving) {
      _showTroubleHint = true;
      notifyListeners();
    }
  }

  void _clearTroubleHint() {
    if (_showTroubleHint) {
      _showTroubleHint = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------ source errors

  /// The camera failed at runtime (disconnected, or the stream kept throwing).
  void _onSourceError(Object error) {
    debugPrint('Scanner source error: $error');
    _sourceFailed = true;
    if (_status != ScannerStatus.scanning &&
        _status != ScannerStatus.processing &&
        _status != ScannerStatus.initializing) {
      return; // a sheet is open; rescan() will restart the camera
    }
    _cancelTimers();
    _troubleTimer?.cancel();
    _troubleTimer = null;
    _resolving = false;
    _showTroubleHint = false;
    _errorMessage = 'The camera stopped working';
    _setStatus(ScannerStatus.error);
  }

  // ---------------------------------------------------------------- helpers

  /// Stops the timers that belong to a running attempt, keeping its state.
  void _suspendTimers() {
    _cancelTimers();
    _troubleTimer?.cancel();
    _troubleTimer = null;
  }

  /// Restarts the timers for the current state. The consensus timeout starts
  /// fresh; the buffer was kept.
  void _resumeTimers() {
    if (_status == ScannerStatus.processing) {
      _timeoutTimer = Timer(_consensusTimeout, _onTimeout);
      _idleTimer = Timer(_idleReset, _onIdle);
    } else if (_status == ScannerStatus.scanning) {
      _restartTroubleTimer();
    }
  }

  void _cancelTimers() {
    _timeoutTimer?.cancel();
    _idleTimer?.cancel();
    _timeoutTimer = null;
    _idleTimer = null;
  }

  /// Not awaited: nothing needs to wait for a subscription to finish
  /// cancelling, and each one is dropped immediately.
  void _cancelSubscriptions() {
    unawaited(_subscription?.cancel());
    unawaited(_brightnessSub?.cancel());
    unawaited(_errorSub?.cancel());
    _subscription = null;
    _brightnessSub = null;
    _errorSub = null;
  }

  /// Clears everything belonging to the current attempt and result.
  void _resetAttempt() {
    _attemptId++;
    _cancelTimers();
    _troubleTimer?.cancel();
    _troubleTimer = null;
    _releaseLock();
    _buffer.reset();
    _advisor.reset();
    _barcodeTooSmall = false;
    _showTroubleHint = false;
    _attemptClock = null;
    _resolving = false;
    _result = null;
    _parseResult = null;
    _isSaved = false;
    _saveFailed = false;
  }

  void _setStatus(ScannerStatus status) {
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
    _cancelTimers();
    for (final timer in [
      _lockTimer,
      _troubleTimer,
      _lowLightTimer,
      _nagPauseTimer,
    ]) {
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
