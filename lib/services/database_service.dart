// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/scan_record.dart';
import '../utils/constants.dart';

/// SQLite access for saved scans. Use [DatabaseService.instance] in the app.
class DatabaseService {
  DatabaseService._({DatabaseFactory? factory, String? path})
    : _factory = factory,
      _pathOverride = path;

  static final DatabaseService instance = DatabaseService._();

  /// A separate, throw-away database that lives only in memory. It never
  /// touches the app's real database file.
  factory DatabaseService.inMemory() =>
      DatabaseService._(path: inMemoryDatabasePath);

  /// Separate instance backed by a custom factory/path (e.g. in-memory FFI).
  @visibleForTesting
  factory DatabaseService.forTesting({
    DatabaseFactory? factory,
    String? path,
  }) => DatabaseService._(factory: factory, path: path);

  final DatabaseFactory? _factory;
  final String? _pathOverride;
  Future<Database>? _dbFuture;

  /// True when the database file failed to open and was recreated empty.
  bool wasResetDueToCorruption = false;

  /// The user has seen the "database reset" notice; clears the flag.
  void acknowledgeCorruptionReset() => wasResetDueToCorruption = false;

  DatabaseFactory get _dbFactory => _factory ?? databaseFactory;

  Future<Database> get database => _dbFuture ??= _open();

  Future<Database> _open() async {
    final path =
        _pathOverride ?? p.join(await _dbFactory.getDatabasesPath(), kDbName);
    try {
      return await _openAt(path);
    } catch (e, st) {
      debugPrint('Database open failed, resetting: $e\n$st');
      try {
        await _dbFactory.deleteDatabase(path);
        final db = await _openAt(path);
        wasResetDueToCorruption = true;
        return db;
      } catch (_) {
        _dbFuture = null; // allow a later retry
        rethrow;
      }
    }
  }

  Future<Database> _openAt(String path) {
    return _dbFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: kDbVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $kTableScanRecords (
        $kColId TEXT PRIMARY KEY,
        $kColRawBarcode TEXT NOT NULL,
        $kColBarcodeFormat TEXT NOT NULL,
        $kColBatchNumber TEXT,
        $kColGtin TEXT,
        $kColExpiryDate TEXT,
        $kColSerialNumber TEXT,
        $kColScanTimestamp TEXT NOT NULL,
        $kColConfidenceScore REAL,
        $kColIsValid INTEGER NOT NULL DEFAULT 1,
        $kColImagePath TEXT,
        $kColMedicineName TEXT,
        $kColStrength TEXT,
        $kColIsOcr INTEGER NOT NULL DEFAULT 0,
        $kColVerifiedByUser INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_scan_timestamp ON $kTableScanRecords '
      '($kColScanTimestamp DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_batch_number ON $kTableScanRecords ($kColBatchNumber)',
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE $kTableScanRecords ADD COLUMN $kColImagePath TEXT',
      );
    }
    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE $kTableScanRecords ADD COLUMN $kColMedicineName TEXT',
      );
      await db.execute(
        'ALTER TABLE $kTableScanRecords ADD COLUMN $kColStrength TEXT',
      );
      await db.execute(
        'ALTER TABLE $kTableScanRecords ADD COLUMN $kColIsOcr INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE $kTableScanRecords ADD COLUMN $kColVerifiedByUser INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  Future<void> insert(ScanRecord record) async {
    final db = await database;
    await db.insert(
      kTableScanRecords,
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Newest first. [batchQuery] matches batch number or GTIN (substring,
  /// case-insensitive).
  Future<List<ScanRecord>> getPage({
    int limit = kHistoryPageSize,
    int offset = 0,
    String? batchQuery,
  }) async {
    final db = await database;
    final filter = _filter(batchQuery);
    final rows = await db.query(
      kTableScanRecords,
      where: filter?.$1,
      whereArgs: filter?.$2,
      orderBy: '$kColScanTimestamp DESC, $kColId DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(ScanRecord.fromMap).toList();
  }

  Future<List<ScanRecord>> getAll() async {
    final db = await database;
    final rows = await db.query(
      kTableScanRecords,
      orderBy: '$kColScanTimestamp DESC, $kColId DESC',
    );
    return rows.map(ScanRecord.fromMap).toList();
  }

  Future<int> count({String? batchQuery}) async {
    final db = await database;
    final filter = _filter(batchQuery);
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $kTableScanRecords'
      '${filter == null ? '' : ' WHERE ${filter.$1}'}',
      filter?.$2,
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<ScanRecord?> getById(String id) async {
    final db = await database;
    final rows = await db.query(
      kTableScanRecords,
      where: '$kColId = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : ScanRecord.fromMap(rows.first);
  }

  /// True if [rawBarcode] was saved within the last [within].
  Future<bool> existsRecentRaw(String rawBarcode, Duration within) async {
    final db = await database;
    final cutoff = DateTime.now().subtract(within).toUtc().toIso8601String();
    final rows = await db.query(
      kTableScanRecords,
      columns: [kColId],
      where: '$kColRawBarcode = ? AND $kColScanTimestamp >= ?',
      whereArgs: [rawBarcode, cutoff],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Timestamp of the newest scan, or null when the table is empty.
  Future<DateTime?> latestScanTimestamp() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT MAX($kColScanTimestamp) AS latest FROM $kTableScanRecords',
    );
    final latest = rows.isEmpty ? null : rows.first['latest'] as String?;
    return latest == null ? null : DateTime.parse(latest).toLocal();
  }

  /// Inserts many records in one transaction (used by the debug seeder).
  Future<void> insertAll(List<ScanRecord> records) async {
    if (records.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final record in records) {
        batch.insert(
          kTableScanRecords,
          record.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> deleteAll() async {
    final db = await database;
    await db.delete(kTableScanRecords);
    await db.execute('VACUUM');
  }

  Future<void> close() async {
    final future = _dbFuture;
    _dbFuture = null;
    if (future != null) await (await future).close();
  }

  /// WHERE clause + args for a search query, or null when there is none.
  /// The query is always bound as a parameter, with LIKE wildcards escaped.
  (String, List<Object?>)? _filter(String? query) {
    final q = query?.trim() ?? '';
    if (q.isEmpty) return null;
    final escaped = q
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final pattern = '%$escaped%';
    return (
      "($kColBatchNumber LIKE ? ESCAPE '\\' OR $kColGtin LIKE ? ESCAPE '\\')",
      [pattern, pattern],
    );
  }
}
