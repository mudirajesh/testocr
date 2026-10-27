import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/providers/history_provider.dart';
import 'package:gs1scan/services/csv_export_service.dart';
import 'package:gs1scan/services/export_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/spy_db.dart';

void main() {
  late SpyDb db;
  late HistoryProvider provider;

  Future<void> waitFor(bool Function() condition, {int ms = 3000}) async {
    for (var i = 0; i < ms ~/ 10 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  HistoryProvider makeProvider({
    Duration debounce = const Duration(milliseconds: 40),
  }) => HistoryProvider(db, searchDebounce: debounce);

  setUp(() async {
    db = SpyDb();
    await db.insertAll(seedRecords(120));
    provider = makeProvider();
  });

  tearDown(() async {
    provider.dispose();
    await db.close();
  });

  group('loading', () {
    test('loadInitial loads the first 50 of 120', () async {
      expect(provider.isLoading, isTrue);
      await provider.loadInitial();

      expect(provider.isLoading, isFalse);
      expect(provider.records.length, 50);
      expect(provider.hasMore, isTrue);
      expect(provider.totalCount, 120);
      expect(provider.matchCount, 120);
      expect(provider.records.first.batchNumber, 'BN119'); // newest first
      expect(
        provider.lastScanAt,
        DateTime(2026, 9, 1, 8).add(const Duration(minutes: 119)),
      );
      expect(provider.error, isNull);
      expect(provider.isEmptyLog, isFalse);
    });

    test('loadMore appends 50, then 20, then stops; no duplicates', () async {
      await provider.loadInitial();

      await provider.loadMore();
      expect(provider.records.length, 100);
      expect(provider.hasMore, isTrue);

      await provider.loadMore();
      expect(provider.records.length, 120);
      expect(provider.hasMore, isFalse);

      final ids = provider.records.map((r) => r.id).toList();
      expect(ids.toSet().length, 120);
      expect(ids.first, 'id-119');
      expect(ids.last, 'id-000');

      final callsBefore = db.pageCalls.length;
      await provider.loadMore(); // nothing left
      expect(db.pageCalls.length, callsBefore);
    });

    test('loadMore while already loading is ignored', () async {
      await provider.loadInitial();
      final before = db.pageCalls.length;

      final first = provider.loadMore();
      expect(provider.isLoadingMore, isTrue);
      final second = provider.loadMore();
      await Future.wait([first, second]);

      expect(db.pageCalls.length, before + 1);
      expect(provider.records.length, 100);
      expect(provider.isLoadingMore, isFalse);
    });

    test('loadMore skips records that are already in the list', () async {
      await provider.loadInitial();
      // A newer scan shifts every row down by one, so the next page repeats
      // the last row of the first page.
      await db.insert(
        ScanRecord(
          id: 'newest',
          rawBarcode: 'x',
          barcodeFormat: 'DataMatrix',
          batchNumber: 'NEW',
          scanTimestamp: DateTime(2030),
        ),
      );
      await provider.loadMore();

      final ids = provider.records.map((r) => r.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids.contains('newest'), isFalse); // not added by paging
    });

    test('isEmptyLog on an empty database', () async {
      await db.deleteAll();
      final empty = makeProvider();
      addTearDown(empty.dispose);
      expect(empty.isEmptyLog, isFalse); // still loading
      await empty.loadInitial();

      expect(empty.isEmptyLog, isTrue);
      expect(empty.totalCount, 0);
      expect(empty.lastScanAt, isNull);
      expect(empty.hasMore, isFalse);
    });
  });

  group('search', () {
    test('by batch fragment, case-insensitive', () async {
      await provider.loadInitial();
      provider.setSearchQuery('bn05');
      await waitFor(() => provider.matchCount == 10);

      expect(provider.matchCount, 10);
      expect(provider.records.length, 10);
      expect(
        provider.records.every((r) => r.batchNumber!.startsWith('BN05')),
        isTrue,
      );
      expect(provider.totalCount, 120, reason: 'total ignores the search');
    });

    test('by GTIN fragment', () async {
      await provider.loadInitial();
      provider.setSearchQuery(
        '0890123'
        '0000042',
      );
      await waitFor(() => provider.matchCount == 1);

      expect(provider.records.single.batchNumber, 'BN042');
    });

    test('three quick keystrokes cause one query', () async {
      await provider.loadInitial();
      db.pageCalls.clear();

      provider.setSearchQuery('b');
      provider.setSearchQuery('bn');
      provider.setSearchQuery('bn0');
      await waitFor(() => provider.matchCount == 100 && !provider.isLoading);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final searchCalls = db.pageCalls.where((c) => c.$1 != '').toList();
      expect(searchCalls.length, 1);
      expect(searchCalls.single.$1, 'bn0');
    });

    test('% matches only literal percent signs', () async {
      await db.insert(
        ScanRecord(
          id: 'pct',
          rawBarcode: 'x',
          barcodeFormat: 'DataMatrix',
          batchNumber: '50%OFF',
          scanTimestamp: DateTime(2026, 10),
        ),
      );
      await provider.loadInitial();
      provider.setSearchQuery('%');
      await waitFor(() => provider.matchCount == 1);

      expect(provider.records.single.batchNumber, '50%OFF');
    });

    test('clearing the search restores the list without waiting', () async {
      final slowDebounce = makeProvider(debounce: const Duration(seconds: 5));
      addTearDown(slowDebounce.dispose);
      await slowDebounce.loadInitial();

      slowDebounce.setSearchQuery('bn05');
      // The search itself is debounced for 5 s; trigger it by hand via a
      // non-debounced path: an empty query must NOT wait.
      slowDebounce.setSearchQuery('');
      await waitFor(() => slowDebounce.records.length == 50);

      expect(slowDebounce.searchQuery, isEmpty);
      expect(slowDebounce.records.length, 50);
      expect(slowDebounce.matchCount, 120);
    });

    test('clearSearch after a real search brings back the full list', () async {
      await provider.loadInitial();
      provider.setSearchQuery('bn05');
      await waitFor(() => provider.matchCount == 10);

      provider.clearSearch();
      await waitFor(() => provider.records.length == 50);

      expect(provider.searchQuery, isEmpty);
      expect(provider.matchCount, 120);
      expect(provider.hasMore, isTrue);
    });

    test('an unchanged query is ignored', () async {
      await provider.loadInitial();
      provider.setSearchQuery('bn05');
      await waitFor(() => provider.matchCount == 10);
      db.pageCalls.clear();

      provider.setSearchQuery('  bn05 ');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(db.pageCalls, isEmpty);
    });

    test('isNoMatches when a search finds nothing', () async {
      await provider.loadInitial();
      provider.setSearchQuery('zzz-nothing');
      await waitFor(() => provider.isNoMatches);

      expect(provider.isNoMatches, isTrue);
      expect(provider.records, isEmpty);
      expect(provider.matchCount, 0);
      expect(provider.totalCount, 120);
      expect(provider.isEmptyLog, isFalse);
    });

    test('a stale slow search result is discarded', () async {
      await db.insertAll([
        ScanRecord(
          id: 'slow-1',
          rawBarcode: 'x',
          barcodeFormat: 'DataMatrix',
          batchNumber: 'SLOW-1',
          scanTimestamp: DateTime(2026, 10, 1),
        ),
        ScanRecord(
          id: 'fast-1',
          rawBarcode: 'x',
          barcodeFormat: 'DataMatrix',
          batchNumber: 'FAST-1',
          scanTimestamp: DateTime(2026, 10, 2),
        ),
      ]);
      await provider.loadInitial();

      db.beforeGetPage = (query) async {
        if (query == 'slow') {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      };

      provider.setSearchQuery('slow');
      await Future<void>.delayed(const Duration(milliseconds: 120)); // started
      provider.setSearchQuery('fast');
      await waitFor(
        () =>
            provider.records.length == 1 &&
            provider.records.single.batchNumber == 'FAST-1',
      );
      expect(provider.records.single.batchNumber, 'FAST-1');

      // The slow query finishes later and must not overwrite the list.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(provider.records.single.batchNumber, 'FAST-1');
      expect(provider.matchCount, 1);
      expect(provider.searchQuery, 'fast');
    });
  });

  group('refresh and errors', () {
    test('refresh keeps the list visible and picks up a new record', () async {
      await provider.loadInitial();
      expect(provider.records.first.batchNumber, 'BN119');

      await db.insert(
        ScanRecord(
          id: 'fresh',
          rawBarcode: 'x',
          barcodeFormat: 'GS1-128',
          batchNumber: 'FRESH',
          scanTimestamp: DateTime(2026, 12),
        ),
      );
      db.beforeGetPage = (_) =>
          Future<void>.delayed(const Duration(milliseconds: 200));

      final refreshing = provider.refresh();
      // While the slow reload runs, nothing flashes to a spinner or empties.
      expect(provider.isLoading, isFalse);
      expect(provider.records.length, 50);
      expect(provider.records.first.batchNumber, 'BN119');

      await refreshing;
      expect(provider.records.first.batchNumber, 'FRESH');
      expect(provider.totalCount, 121);
      expect(provider.lastScanAt, DateTime(2026, 12));
    });

    test('a failed load sets error and keeps the previous records', () async {
      await provider.loadInitial();
      expect(provider.error, isNull);

      db.failReads = true;
      await provider.refresh();

      expect(provider.error, isNotNull);
      expect(provider.records.length, 50);
      expect(provider.totalCount, 120);
      expect(provider.isLoading, isFalse);
    });

    test('a failed first load leaves an error with no records; retry '
        'recovers', () async {
      db.failReads = true;
      await provider.loadInitial();
      expect(provider.error, isNotNull);
      expect(provider.records, isEmpty);
      expect(provider.isLoading, isFalse);

      db.failReads = false;
      await provider.retry();

      expect(provider.error, isNull);
      expect(provider.records.length, 50);
      expect(provider.totalCount, 120);
    });

    test('clearAll empties everything', () async {
      await provider.loadInitial();
      await provider.clearAll();

      expect(provider.records, isEmpty);
      expect(provider.totalCount, 0);
      expect(provider.matchCount, 0);
      expect(provider.lastScanAt, isNull);
      expect(provider.isEmptyLog, isTrue);
      expect(await db.count(), 0);
    });

    test('a load finishing after dispose does not notify or throw', () async {
      final late = makeProvider();
      db.beforeGetPage = (_) =>
          Future<void>.delayed(const Duration(milliseconds: 100));
      final loading = late.loadInitial();
      late.dispose();
      await expectLater(loading, completes);
    });

    test('onRecordSaved-style refresh updates count and last scan', () async {
      await provider.loadInitial();
      await db.insert(
        ScanRecord(
          id: 'saved',
          rawBarcode: 'x',
          barcodeFormat: 'DataMatrix',
          batchNumber: 'SAVED',
          scanTimestamp: DateTime(2027),
        ),
      );
      await provider.refresh();

      expect(provider.totalCount, 121);
      expect(provider.lastScanAt, DateTime(2027));
      expect(provider.records.first.batchNumber, 'SAVED');
    });
  });

  group('export and clear', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('gs1_provider_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    HistoryProvider withExporter({
      Future<void> Function(File file)? share,
      ExportTracker? tracker,
    }) {
      final exporter = CsvExportService(
        db: db,
        tempDir: () async => tempDir,
        share: share ?? (_) async {},
        freeBytes: () async => null,
      );
      final p = HistoryProvider(db, exporter: exporter, tracker: tracker);
      addTearDown(p.dispose);
      return p;
    }

    test('exportCsv ignores a second call while one is running', () async {
      final gate = Completer<void>();
      var shareCalls = 0;
      final p = withExporter(
        share: (_) async {
          shareCalls++;
          await gate.future;
        },
      );

      final first = p.exportCsv();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(p.isExporting, isTrue);

      final second = await p.exportCsv();
      expect(second.outcome, ExportOutcome.failed);
      expect(shareCalls, 1);

      gate.complete();
      final result = await first;
      expect(result.outcome, ExportOutcome.success);
      expect(p.isExporting, isFalse);
      expect(shareCalls, 1);
    });

    test('a successful export records the export time', () async {
      final tracker = ExportTracker();
      final p = withExporter(tracker: tracker);

      expect(await tracker.lastExportAt(), isNull);
      expect(await p.shouldWarnNotExported(), isTrue);

      await p.exportCsv();

      expect(await tracker.lastExportAt(), isNotNull);
      expect(await p.shouldWarnNotExported(), isFalse);
    });

    test('a failed or empty export does not record anything', () async {
      final tracker = ExportTracker();
      final failing = withExporter(
        share: (_) async => throw StateError('no share'),
        tracker: tracker,
      );
      expect((await failing.exportCsv()).outcome, ExportOutcome.failed);
      expect(await tracker.lastExportAt(), isNull);
      expect(failing.isExporting, isFalse);

      await db.deleteAll();
      final empty = withExporter(tracker: tracker);
      expect((await empty.exportCsv()).outcome, ExportOutcome.empty);
      expect(await tracker.lastExportAt(), isNull);
    });

    test('exportCsv exports every record, not only the loaded page', () async {
      final p = withExporter();
      await p.loadInitial();
      expect(p.records.length, 50);

      final result = await p.exportCsv();
      expect(result.rowCount, 120);
    });

    test('freshTotalCount ignores the search', () async {
      await provider.loadInitial();
      provider.setSearchQuery('bn05');
      await waitFor(() => provider.matchCount == 10);

      expect(await provider.freshTotalCount(), 120);
    });

    test('clearAllRecords empties the database and the state', () async {
      await provider.loadInitial();
      final ok = await provider.clearAllRecords();

      expect(ok, isTrue);
      expect(await db.count(), 0);
      expect(provider.totalCount, 0);
      expect(provider.records, isEmpty);
      expect(provider.isEmptyLog, isTrue);
      expect(provider.isClearing, isFalse);
    });

    test('clearAllRecords on a failing database keeps the records', () async {
      await provider.loadInitial();
      db.failDelete = true;

      final ok = await provider.clearAllRecords();

      expect(ok, isFalse);
      expect(provider.totalCount, 120);
      expect(provider.records.length, 50);
      expect(provider.isEmptyLog, isFalse);
      expect(provider.isClearing, isFalse);
      expect(await db.count(), 120);
    });

    test('clearAllRecords ignores a second call while running', () async {
      await provider.loadInitial();
      final first = provider.clearAllRecords();
      final second = await provider.clearAllRecords();
      expect(second, isFalse);
      expect(await first, isTrue);
    });

    test('clearing does not reset the export tracker', () async {
      final tracker = ExportTracker();
      final p = withExporter(tracker: tracker);
      await p.exportCsv();
      final exportedAt = await tracker.lastExportAt();

      await p.clearAllRecords();
      expect(await tracker.lastExportAt(), exportedAt);
    });
  });
}
