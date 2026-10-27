import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/services/export_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/spy_db.dart';

ScanRecord scanAt(String id, DateTime at) => ScanRecord(
  id: id,
  rawBarcode: 'x',
  barcodeFormat: 'DataMatrix',
  batchNumber: 'B',
  scanTimestamp: at,
);

void main() {
  late SpyDb db;
  late ExportTracker tracker;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = SpyDb();
    tracker = ExportTracker();
  });

  tearDown(() => db.close());

  test('never exported and records exist: warn', () async {
    await db.insert(scanAt('1', DateTime(2026, 9, 1)));
    expect(await tracker.lastExportAt(), isNull);
    expect(await tracker.needsExportWarning(db), isTrue);
  });

  test('no records: never warn', () async {
    expect(await tracker.needsExportWarning(db), isFalse);
    await tracker.markExported(DateTime(2026, 9, 2));
    expect(await tracker.needsExportWarning(db), isFalse);
  });

  test('exported after the latest scan: no warning', () async {
    await db.insert(scanAt('1', DateTime(2026, 9, 1, 10)));
    await tracker.markExported(DateTime(2026, 9, 1, 11));
    expect(await tracker.needsExportWarning(db), isFalse);
  });

  test('a newer scan after the export warns again', () async {
    await db.insert(scanAt('1', DateTime(2026, 9, 1, 10)));
    await tracker.markExported(DateTime(2026, 9, 1, 11));
    await db.insert(scanAt('2', DateTime(2026, 9, 1, 12)));
    expect(await tracker.needsExportWarning(db), isTrue);
  });

  test('lastExportAt round-trips and survives a new tracker', () async {
    final when = DateTime(2026, 9, 5, 8, 30, 15);
    await tracker.markExported(when);
    expect(await tracker.lastExportAt(), when);
    expect(await ExportTracker().lastExportAt(), when);
  });

  test('clearing records does not reset the tracker', () async {
    await db.insert(scanAt('1', DateTime(2026, 9, 1)));
    await tracker.markExported(DateTime(2026, 9, 2));
    await db.deleteAll();
    expect(await tracker.lastExportAt(), DateTime(2026, 9, 2));
  });
}
