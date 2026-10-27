import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Wraps a real in-memory [DatabaseService] and lets tests count queries,
/// delay them and make reads fail.
class SpyDb implements DatabaseService {
  SpyDb() {
    sqfliteFfiInit();
    inner = DatabaseService.forTesting(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
  }

  late final DatabaseService inner;

  /// Every getPage call as (query, offset).
  final List<(String?, int)> pageCalls = [];

  /// Runs before each getPage; return a Future to delay it.
  Future<void> Function(String? query)? beforeGetPage;

  /// Makes every read throw.
  bool failReads = false;

  /// Makes deleteAll throw.
  bool failDelete = false;

  /// Makes insert and insertAll throw.
  bool failInsert = false;

  void _checkReads() {
    if (failReads) throw StateError('read failed');
  }

  @override
  bool get wasResetDueToCorruption => inner.wasResetDueToCorruption;

  @override
  set wasResetDueToCorruption(bool value) =>
      inner.wasResetDueToCorruption = value;

  @override
  void acknowledgeCorruptionReset() => inner.acknowledgeCorruptionReset();

  @override
  Future<Database> get database => inner.database;

  @override
  Future<void> insert(ScanRecord record) async {
    if (failInsert) throw StateError('insert failed');
    await inner.insert(record);
  }

  @override
  Future<void> insertAll(List<ScanRecord> records) async {
    if (failInsert) throw StateError('insert failed');
    await inner.insertAll(records);
  }

  @override
  Future<List<ScanRecord>> getPage({
    int limit = 50,
    int offset = 0,
    String? batchQuery,
  }) async {
    pageCalls.add((batchQuery, offset));
    await beforeGetPage?.call(batchQuery);
    _checkReads();
    return inner.getPage(limit: limit, offset: offset, batchQuery: batchQuery);
  }

  @override
  Future<List<ScanRecord>> getAll() => inner.getAll();

  @override
  Future<int> count({String? batchQuery}) async {
    _checkReads();
    return inner.count(batchQuery: batchQuery);
  }

  @override
  Future<DateTime?> latestScanTimestamp() async {
    _checkReads();
    return inner.latestScanTimestamp();
  }

  @override
  Future<ScanRecord?> getById(String id) => inner.getById(id);

  @override
  Future<bool> existsRecentRaw(String rawBarcode, Duration within) =>
      inner.existsRecentRaw(rawBarcode, within);

  @override
  Future<void> deleteAll() async {
    if (failDelete) throw StateError('delete failed');
    await inner.deleteAll();
  }

  @override
  Future<void> close() => inner.close();
}

/// [count] records, newest = highest index. Batches BN000.., GTINs unique.
List<ScanRecord> seedRecords(int count, {DateTime? from}) {
  final start = from ?? DateTime(2026, 9, 1, 8);
  return [
    for (var i = 0; i < count; i++)
      ScanRecord(
        id: 'id-${i.toString().padLeft(3, '0')}',
        rawBarcode: 'raw-$i',
        barcodeFormat: 'DataMatrix',
        batchNumber: 'BN${i.toString().padLeft(3, '0')}',
        gtin: '0890123${i.toString().padLeft(7, '0')}',
        expiryDate: '271231',
        scanTimestamp: start.add(Duration(minutes: i)),
        confidenceScore: 1.0,
        isValid: i % 10 != 9,
      ),
  ];
}
