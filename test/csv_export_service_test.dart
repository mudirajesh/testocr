import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/services/csv_export_service.dart';
import 'package:gs1scan/utils/constants.dart';

import 'support/spy_db.dart';

void main() {
  late SpyDb db;
  late Directory dir;
  late List<File> shared;
  Future<void> Function(File)? shareBehaviour;
  Future<int?> Function() freeBehaviour = () async => 100 * 1024 * 1024;

  final fixedNow = DateTime(2026, 9, 29, 14, 5, 9);

  CsvExportService service({DateTime Function()? now}) => CsvExportService(
    db: db,
    tempDir: () async => dir,
    share: (file) async {
      shared.add(file);
      await shareBehaviour?.call(file);
    },
    freeBytes: () => freeBehaviour(),
    now: now ?? () => fixedNow,
  );

  setUp(() async {
    db = SpyDb();
    dir = await Directory.systemTemp.createTemp('gs1_export_test');
    shared = [];
    shareBehaviour = null;
    freeBehaviour = () async => 100 * 1024 * 1024;
  });

  tearDown(() async {
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  List<File> csvFiles() => dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.csv'))
      .toList();

  test(
    'an empty database gives empty, writes nothing and never shares',
    () async {
      final result = await service().export();

      expect(result.outcome, ExportOutcome.empty);
      expect(result.path, isNull);
      expect(csvFiles(), isEmpty);
      expect(shared, isEmpty);
    },
  );

  test('success writes gs1_scan_YYYYMMDD_HHMMSS.csv and shares it', () async {
    await db.insertAll(seedRecords(3));
    final result = await service().export();

    expect(result.outcome, ExportOutcome.success);
    expect(result.rowCount, 3);
    expect(shared.length, 1);
    expect(shared.single.path, result.path);

    final name = result.path!.split(Platform.pathSeparator).last;
    expect(name, matches(RegExp(r'^gs1_scan_\d{8}_\d{6}\.csv$')));
    expect(name, 'gs1_scan_20260929_140509.csv');
    expect(name.startsWith(kCsvFilePrefix), isTrue);
  });

  test('the file starts with a UTF-8 BOM and decodes as UTF-8', () async {
    await db.insert(
      ScanRecord(
        id: '1',
        rawBarcode: 'raw',
        barcodeFormat: 'DataMatrix',
        batchNumber: 'बैच-१२३',
        scanTimestamp: DateTime(2026, 9, 29),
      ),
    );
    final result = await service().export();
    final bytes = await File(result.path!).readAsBytes();

    expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
    final text = utf8.decode(bytes.sublist(3));
    expect(text, contains('बैच-१२३'));
    expect(text.startsWith('Sr. No.,Batch Number'), isTrue);
  });

  test('records are exported newest first with the right row count', () async {
    await db.insertAll(seedRecords(5)); // BN000 oldest .. BN004 newest
    final result = await service().export();

    expect(result.rowCount, 5);
    final text = utf8.decode(
      (await File(result.path!).readAsBytes()).sublist(3),
    );
    final rows = Csv().decode(text);
    expect(rows.length, 6);
    expect(rows.skip(1).map((r) => r[1]), [
      'BN004',
      'BN003',
      'BN002',
      'BN001',
      'BN000',
    ]);
    expect(rows.skip(1).map((r) => r[0].toString()), ['1', '2', '3', '4', '5']);
  });

  test('low free space gives lowStorage and no file', () async {
    await db.insertAll(seedRecords(2));
    freeBehaviour = () async => kCsvMinFreeBytes - 1;

    final result = await service().export();

    expect(result.outcome, ExportOutcome.lowStorage);
    expect(csvFiles(), isEmpty);
    expect(shared, isEmpty);
  });

  test('ignoreLowStorage exports anyway', () async {
    await db.insertAll(seedRecords(2));
    freeBehaviour = () async => 1024;

    final result = await service().export(ignoreLowStorage: true);

    expect(result.outcome, ExportOutcome.success);
    expect(csvFiles().length, 1);
  });

  test('exactly 5 MB free is enough', () async {
    await db.insertAll(seedRecords(1));
    freeBehaviour = () async => kCsvMinFreeBytes;
    expect((await service().export()).outcome, ExportOutcome.success);
  });

  test('an unavailable or failing free-space check is skipped', () async {
    await db.insertAll(seedRecords(1));

    freeBehaviour = () async => null;
    expect((await service().export()).outcome, ExportOutcome.success);

    freeBehaviour = () async => throw StateError('no plugin');
    expect((await service().export()).outcome, ExportOutcome.success);
  });

  test('a failing share gives failed and nothing escapes', () async {
    await db.insertAll(seedRecords(2));
    shareBehaviour = (_) async => throw StateError('no app can share');

    final result = await service().export();

    expect(result.outcome, ExportOutcome.failed);
    expect(result.error, isA<StateError>());
  });

  test('a failing database read gives failed', () async {
    await db.insertAll(seedRecords(2));
    db.failReads = true;
    final result = await service().export();
    expect(result.outcome, ExportOutcome.failed);
    expect(shared, isEmpty);
  });

  test('a missing temp directory gives failed', () async {
    await db.insertAll(seedRecords(1));
    final broken = CsvExportService(
      db: db,
      tempDir: () async => Directory('${dir.path}/does/not/exist'),
      share: (_) async {},
      freeBytes: () async => null,
    );
    expect((await broken.export()).outcome, ExportOutcome.failed);
  });

  test('a large export (over 2000 rows) uses the background builder', () async {
    await db.insertAll(seedRecords(2100));
    final result = await service().export();

    expect(result.outcome, ExportOutcome.success);
    expect(result.rowCount, 2100);
    final text = utf8.decode(
      (await File(result.path!).readAsBytes()).sublist(3),
    );
    expect(Csv().decode(text).length, 2101);
  });

  group('cleanupOldExports', () {
    Future<File> makeFile(String name, {required Duration age}) async {
      final file = File('${dir.path}/$name');
      await file.writeAsString('x');
      await file.setLastModified(fixedNow.subtract(age));
      return file;
    }

    test('deletes old gs1_scan_*.csv and leaves everything else', () async {
      final oldExport = await makeFile(
        'gs1_scan_20260101_000000.csv',
        age: const Duration(days: 3),
      );
      final freshExport = await makeFile(
        'gs1_scan_20260929_120000.csv',
        age: const Duration(hours: 2),
      );
      final otherCsv = await makeFile(
        'other.csv',
        age: const Duration(days: 30),
      );
      final otherFile = await makeFile(
        'gs1_scan_notes.txt',
        age: const Duration(days: 30),
      );

      await service().cleanupOldExports();

      expect(await oldExport.exists(), isFalse);
      expect(await freshExport.exists(), isTrue);
      expect(await otherCsv.exists(), isTrue);
      expect(await otherFile.exists(), isTrue);
    });

    test('olderThan is respected', () async {
      final file = await makeFile(
        'gs1_scan_20260929_120000.csv',
        age: const Duration(hours: 2),
      );
      await service().cleanupOldExports(olderThan: const Duration(hours: 1));
      expect(await file.exists(), isFalse);
    });

    test('a missing folder is not an error', () async {
      final gone = CsvExportService(
        db: db,
        tempDir: () async => Directory('${dir.path}/missing'),
      );
      await expectLater(gone.cleanupOldExports(), completes);
    });
  });
}
