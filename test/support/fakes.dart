import 'dart:async';

import 'package:camera/camera.dart';
import 'package:gs1scan/models/detected_barcode.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/services/barcode_scanner_service.dart';
import 'package:gs1scan/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

/// A camera stand-in the tests can drive: detections, brightness and errors
/// are emitted by hand, and every call is recorded.
class FakeBarcodeSource implements BarcodeDetectionSource {
  final StreamController<DetectedBarcode?> _detections =
      StreamController<DetectedBarcode?>.broadcast();
  final StreamController<double> _brightness =
      StreamController<double>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();

  Object? startError;
  int startCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int disposeCalls = 0;
  bool? lastTorch;
  bool torchResult = true;
  bool permissionGranted = true;
  final List<double> zoomCalls = [];

  @override
  bool supportsZoom = true;

  @override
  double averageFrameMillis = 0;

  void emit(
    String raw, {
    String format = 'dataMatrix',
    double widthFraction = 0.5,
  }) => _detections.add(
    DetectedBarcode(
      rawValue: raw,
      format: format,
      centerX: 0.5,
      centerY: 0.5,
      widthFraction: widthFraction,
    ),
  );

  void emitNone() => _detections.add(null);
  void emitBrightness(double value) => _brightness.add(value);
  void emitError(Object error) => _errors.add(error);

  @override
  Stream<DetectedBarcode?> get detections => _detections.stream;

  @override
  Stream<double> get brightness => _brightness.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  CameraController? get cameraController => null;

  @override
  Future<void> start() async {
    startCalls++;
    if (startError != null) throw startError!;
  }

  @override
  Future<void> pause() async => pauseCalls++;

  @override
  Future<void> resume() async => resumeCalls++;

  @override
  Future<bool> setTorch(bool on) async {
    lastTorch = on;
    return torchResult;
  }

  @override
  Future<void> setZoom(double level) async => zoomCalls.add(level);

  @override
  Future<bool> isCameraPermissionGranted() async => permissionGranted;

  String? pictureResult;
  int takePictureCalls = 0;

  @override
  Future<String?> takePicture() async {
    takePictureCalls++;
    return pictureResult;
  }

  @override
  Future<void> dispose() async => disposeCalls++;
}

/// In-memory stand-in for DatabaseService. Real sqflite needs real async I/O,
/// which fake_async cannot drive, so timer-based scenarios use this.
class FakeDb implements DatabaseService {
  final List<ScanRecord> rows = [];
  bool failInsert = false;
  bool failExists = false;
  int insertCalls = 0;

  /// Fake time, advanced by the tests next to `async.elapse`. Used for
  /// [existsRecentRaw] because DateTime.now() is not faked.
  Duration elapsed = Duration.zero;
  final Map<String, Duration> _insertedAt = {};

  @override
  bool wasResetDueToCorruption = false;

  @override
  void acknowledgeCorruptionReset() => wasResetDueToCorruption = false;

  @override
  Future<Database> get database => throw UnimplementedError();

  @override
  Future<void> insert(ScanRecord record) async {
    insertCalls++;
    if (failInsert) throw StateError('disk full');
    rows.add(record);
    _insertedAt[record.id] = elapsed;
  }

  @override
  Future<void> insertAll(List<ScanRecord> records) async {
    for (final r in records) {
      await insert(r);
    }
  }

  @override
  Future<DateTime?> latestScanTimestamp() async => null;

  @override
  Future<int> count({String? batchQuery}) async => rows.length;

  @override
  Future<List<ScanRecord>> getPage({
    int limit = 50,
    int offset = 0,
    String? batchQuery,
  }) async => rows;

  @override
  Future<List<ScanRecord>> getAll() async => rows;

  @override
  Future<ScanRecord?> getById(String id) async =>
      rows.where((r) => r.id == id).firstOrNull;

  @override
  Future<bool> existsRecentRaw(String rawBarcode, Duration within) async {
    if (failExists) throw StateError('lookup failed');
    return rows.any(
      (r) =>
          r.rawBarcode == rawBarcode && elapsed - _insertedAt[r.id]! < within,
    );
  }

  @override
  Future<void> deleteAll() async => rows.clear();

  @override
  Future<void> close() async {}
}
