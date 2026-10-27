import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ScanRecord _rec(
  String id, {
  String raw = 'raw',
  String? batch,
  String? gtin,
  required DateTime at,
  bool isValid = true,
  double? confidence,
}) => ScanRecord(
  id: id,
  rawBarcode: raw,
  barcodeFormat: 'GS1-128',
  batchNumber: batch,
  gtin: gtin,
  scanTimestamp: at,
  confidenceScore: confidence,
  isValid: isValid,
);

void main() {
  sqfliteFfiInit();

  late DatabaseService db;

  setUp(() {
    db = DatabaseService.forTesting(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
  });

  tearDown(() => db.close());

  final base = DateTime(2026, 9, 29, 12);

  test('insert then getById round-trips all fields', () async {
    final r = ScanRecord(
      id: 'a',
      rawBarcode: '(01)08901234567890(17)261231(10)B1(21)S1',
      barcodeFormat: 'DataMatrix',
      batchNumber: 'B1',
      gtin: '08901234567890',
      expiryDate: '261231',
      serialNumber: 'S1',
      scanTimestamp: base,
      confidenceScore: 0.9,
    );
    await db.insert(r);
    final got = await db.getById('a');
    expect(got, r);
    expect(got!.rawBarcode, r.rawBarcode);
    expect(got.barcodeFormat, 'DataMatrix');
    expect(got.batchNumber, 'B1');
    expect(got.gtin, '08901234567890');
    expect(got.expiryDate, '261231');
    expect(got.serialNumber, 'S1');
    expect(got.scanTimestamp, base);
    expect(got.confidenceScore, 0.9);
    expect(got.isValid, true);
  });

  test('null fields and isValid=false round-trip', () async {
    await db.insert(_rec('n', at: base, isValid: false));
    final got = (await db.getById('n'))!;
    expect(got.batchNumber, isNull);
    expect(got.gtin, isNull);
    expect(got.confidenceScore, isNull);
    expect(got.isValid, false);
    expect(await db.getById('missing'), isNull);
  });

  test('getPage is newest first and respects limit/offset', () async {
    for (var i = 0; i < 5; i++) {
      await db.insert(_rec('r$i', at: base.add(Duration(minutes: i))));
    }
    final all = await db.getPage();
    expect(all.map((r) => r.id), ['r4', 'r3', 'r2', 'r1', 'r0']);

    final page = await db.getPage(limit: 2, offset: 1);
    expect(page.map((r) => r.id), ['r3', 'r2']);

    expect((await db.getAll()).map((r) => r.id), [
      'r4',
      'r3',
      'r2',
      'r1',
      'r0',
    ]);
  });

  test('getPage filters by batch and GTIN, case-insensitively', () async {
    await db.insert(_rec('1', batch: 'LOT-ABC', gtin: '111', at: base));
    await db.insert(
      _rec(
        '2',
        batch: 'LOT-XYZ',
        gtin: '222',
        at: base.add(const Duration(minutes: 1)),
      ),
    );
    await db.insert(
      _rec('3', gtin: '333', at: base.add(const Duration(minutes: 2))),
    );

    expect((await db.getPage(batchQuery: 'lot-abc')).map((r) => r.id), ['1']);
    expect((await db.getPage(batchQuery: 'LOT')).map((r) => r.id), ['2', '1']);
    expect((await db.getPage(batchQuery: '333')).map((r) => r.id), ['3']);
    expect(await db.getPage(batchQuery: 'nothing'), isEmpty);
    expect((await db.getPage(batchQuery: '')).length, 3);
    expect((await db.getPage(batchQuery: null)).length, 3);
  });

  test('queries are parameterised and wildcards are escaped', () async {
    await db.insert(_rec('1', batch: 'LOT_1', at: base));
    await db.insert(_rec('2', batch: 'LOTX1', at: base));
    expect((await db.getPage(batchQuery: 'LOT_1')).map((r) => r.id), ['1']);
    expect(
      await db.getPage(batchQuery: "'; DROP TABLE scan_records; --"),
      isEmpty,
    );
    expect(await db.count(), 2);
  });

  test('count with and without a query', () async {
    await db.insert(_rec('1', batch: 'AAA', at: base));
    await db.insert(_rec('2', batch: 'AAB', at: base));
    await db.insert(_rec('3', batch: 'CCC', at: base));
    expect(await db.count(), 3);
    expect(await db.count(batchQuery: 'aa'), 2);
    expect(await db.count(batchQuery: 'zzz'), 0);
  });

  test('existsRecentRaw respects the time window', () async {
    final now = DateTime.now();
    await db.insert(
      _rec('1', raw: 'CODE', at: now.subtract(const Duration(minutes: 10))),
    );
    expect(await db.existsRecentRaw('CODE', const Duration(minutes: 30)), true);
    expect(await db.existsRecentRaw('CODE', const Duration(minutes: 5)), false);
    expect(
      await db.existsRecentRaw('OTHER', const Duration(minutes: 30)),
      false,
    );
  });

  test('deleteAll empties the table', () async {
    await db.insert(_rec('1', at: base));
    await db.insert(_rec('2', at: base));
    await db.deleteAll();
    expect(await db.count(), 0);
    expect(await db.getPage(), isEmpty);
  });

  test('a fresh database is not flagged as corrupted', () async {
    await db.database;
    expect(db.wasResetDueToCorruption, false);
  });

  group('step 5 additions', () {
    test('LIKE wildcards in the query match literally', () async {
      await db.insert(_rec('1', batch: '100%PURE', at: base));
      await db.insert(_rec('2', batch: '100XPURE', at: base));
      await db.insert(_rec('3', batch: 'A_B', at: base));
      await db.insert(_rec('4', batch: 'AXB', at: base));
      await db.insert(_rec('5', batch: r'BACK\SLASH', at: base));

      expect((await db.getPage(batchQuery: '%')).map((r) => r.id), ['1']);
      expect(await db.count(batchQuery: '%'), 1);
      expect((await db.getPage(batchQuery: '_')).map((r) => r.id), ['3']);
      expect(await db.count(batchQuery: '_'), 1);
      expect((await db.getPage(batchQuery: r'\')).map((r) => r.id), ['5']);
      expect(await db.count(batchQuery: '100%'), 1);
    });

    test('equal timestamps are ordered by id descending', () async {
      for (final id in ['a', 'c', 'b']) {
        await db.insert(_rec(id, at: base));
      }
      expect((await db.getPage()).map((r) => r.id), ['c', 'b', 'a']);
      expect((await db.getAll()).map((r) => r.id), ['c', 'b', 'a']);
      // Stable paging across a tie.
      expect((await db.getPage(limit: 1, offset: 0)).single.id, 'c');
      expect((await db.getPage(limit: 1, offset: 1)).single.id, 'b');
      expect((await db.getPage(limit: 1, offset: 2)).single.id, 'a');
    });

    test('latestScanTimestamp is null when empty, else the newest', () async {
      expect(await db.latestScanTimestamp(), isNull);
      await db.insert(_rec('1', at: base));
      await db.insert(_rec('2', at: base.add(const Duration(hours: 5))));
      await db.insert(_rec('3', at: base.subtract(const Duration(days: 2))));
      expect(
        await db.latestScanTimestamp(),
        base.add(const Duration(hours: 5)),
      );
    });

    test('insertAll stores every record in one go', () async {
      await db.insertAll([
        for (var i = 0; i < 120; i++)
          _rec(
            'r$i',
            batch: 'B$i',
            at: base.add(Duration(minutes: i)),
          ),
      ]);
      expect(await db.count(), 120);
      expect((await db.getPage(limit: 1)).single.id, 'r119');
      await db.insertAll(const []); // no-op
      expect(await db.count(), 120);
    });
  });
}
