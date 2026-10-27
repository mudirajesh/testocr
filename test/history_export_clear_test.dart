import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/providers/history_provider.dart';
import 'package:gs1scan/screens/history_screen.dart';
import 'package:gs1scan/services/csv_export_service.dart';
import 'package:gs1scan/services/database_service.dart';
import 'package:gs1scan/services/export_tracker.dart';
import 'package:gs1scan/widgets/history_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/spy_db.dart';

ScanRecord rec(String id, {int minute = 0}) => ScanRecord(
  id: id,
  rawBarcode: 'raw-$id',
  barcodeFormat: 'DataMatrix',
  batchNumber: 'BN-$id',
  gtin: '08901234567890',
  expiryDate: '271231',
  scanTimestamp: DateTime(2026, 9, 29, 10, minute),
  confidenceScore: 1.0,
);

void main() {
  late SpyDb db;
  late List<File> shared;
  Future<int?> Function() freeBehaviour = () async => null;
  Future<void> Function(File)? shareBehaviour;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = SpyDb();
    shared = [];
    freeBehaviour = () async => null;
    shareBehaviour = null;
  });

  Future<HistoryProvider> pumpHistory(
    WidgetTester tester, {
    List<ScanRecord> records = const [],
    bool exportedAlready = false,
    double textScale = 1.0,
    Size size = const Size(400, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => tester.runAsync(db.close));

    final tempDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('gs1_widget_export'),
    );
    addTearDown(
      () => tester.runAsync(() async {
        if (await tempDir!.exists()) await tempDir.delete(recursive: true);
      }),
    );

    final tracker = ExportTracker();
    final exporter = CsvExportService(
      db: db,
      tempDir: () async => tempDir!,
      share: (file) async {
        shared.add(file);
        await shareBehaviour?.call(file);
      },
      freeBytes: () => freeBehaviour(),
    );
    final provider = HistoryProvider(
      db,
      searchDebounce: const Duration(milliseconds: 10),
      exporter: exporter,
      tracker: tracker,
    );
    addTearDown(provider.dispose);

    await tester.runAsync(() async {
      await db.insertAll(records);
      if (exportedAlready) await tracker.markExported(DateTime(2027));
      await provider.loadInitial();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<DatabaseService>.value(value: db),
          ChangeNotifierProvider<HistoryProvider>.value(value: provider),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const HistoryScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    return provider;
  }

  /// Lets real database / file I/O finish, then renders the result. Each step
  /// of an async chain needs the real event loop and then a pump to continue,
  /// so alternate a few times.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> openClearDialog(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Clear all'));
    await tester.pump();
    await settleIo(tester);
  }

  final threeRecords = [
    rec('a', minute: 3),
    rec('b', minute: 2),
    rec('c', minute: 1),
  ];

  group('export', () {
    testWidgets('on an empty database shows No scan records to export', (
      tester,
    ) async {
      await pumpHistory(tester);

      await tester.tap(find.byTooltip('Export'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('No scan records to export'), findsOneWidget);
      expect(shared, isEmpty);
    });

    testWidgets('success shares the file and shows CSV exported successfully', (
      tester,
    ) async {
      await pumpHistory(tester, records: threeRecords);

      await tester.tap(find.byTooltip('Export').first);
      await tester.pump();
      await settleIo(tester);

      expect(shared.length, 1);
      expect(find.text('CSV exported successfully'), findsOneWidget);
      expect(find.text('Export coming soon'), findsNothing);
    });

    testWidgets('a failing share shows the failure message', (tester) async {
      shareBehaviour = (_) async => throw StateError('no share');
      await pumpHistory(tester, records: threeRecords);

      await tester.tap(find.byTooltip('Export').first);
      await tester.pump();
      await settleIo(tester);

      expect(find.text('Export failed. Please try again.'), findsOneWidget);
    });

    testWidgets('low storage asks first and Export anyway exports', (
      tester,
    ) async {
      freeBehaviour = () async => 1024;
      await pumpHistory(tester, records: threeRecords);

      await tester.tap(find.byTooltip('Export').first);
      await tester.pump();
      await settleIo(tester);

      expect(find.text('Low storage'), findsOneWidget);
      expect(
        find.text('Less than 5 MB of free space is left. The export may fail.'),
        findsOneWidget,
      );
      expect(shared, isEmpty);

      await tester.tap(find.text('Export anyway'));
      await tester.pump();
      await settleIo(tester);

      expect(shared.length, 1);
      expect(find.text('CSV exported successfully'), findsOneWidget);
    });

    testWidgets('low storage Cancel exports nothing', (tester) async {
      freeBehaviour = () async => 1024;
      await pumpHistory(tester, records: threeRecords);

      await tester.tap(find.byTooltip('Export').first);
      await tester.pump();
      await settleIo(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await settleIo(tester);

      expect(shared, isEmpty);
      expect(find.text('Low storage'), findsNothing);
    });

    testWidgets('both download icons start the same export', (tester) async {
      await pumpHistory(tester, records: threeRecords);
      expect(find.byTooltip('Export'), findsNWidgets(2));

      await tester.tap(find.byTooltip('Export').last);
      await tester.pump();
      await settleIo(tester);
      expect(shared.length, 1);
    });
  });

  group('clear all', () {
    testWidgets('dialog shows the count and cannot be dismissed', (
      tester,
    ) async {
      await pumpHistory(tester, records: threeRecords);
      await openClearDialog(tester);

      expect(find.text('Clear All Scan Records?'), findsOneWidget);
      expect(
        find.textContaining('permanently delete all 3 stored scan records.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('This action cannot be undone.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Consider exporting to CSV first.'),
        findsOneWidget,
      );

      // Tapping outside does nothing.
      await tester.tapAt(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Clear All Scan Records?'), findsOneWidget);

      // Neither does the system back button.
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Clear All Scan Records?'), findsOneWidget);
    });

    testWidgets('a single record uses the singular wording', (tester) async {
      await pumpHistory(tester, records: [rec('a')]);
      await openClearDialog(tester);
      expect(
        find.textContaining('permanently delete the 1 stored scan record.'),
        findsOneWidget,
      );
    });

    testWidgets('Cancel keeps the records', (tester) async {
      final provider = await pumpHistory(tester, records: threeRecords);
      await openClearDialog(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await settleIo(tester);

      expect(find.text('Clear All Scan Records?'), findsNothing);
      expect(find.byType(HistoryCard), findsNWidgets(3));
      expect(provider.totalCount, 3);
      expect(await tester.runAsync(db.count), 3);
    });

    testWidgets('the not-exported warning shows only when it applies', (
      tester,
    ) async {
      await pumpHistory(tester, records: threeRecords);
      await openClearDialog(tester);
      expect(
        find.text('You have not exported your data recently.'),
        findsOneWidget,
      );
      expect(find.text('Export first'), findsOneWidget);
    });

    testWidgets('no warning when the data was exported after the last scan', (
      tester,
    ) async {
      await pumpHistory(tester, records: threeRecords, exportedAlready: true);
      await openClearDialog(tester);

      expect(find.text('Clear All Scan Records?'), findsOneWidget);
      expect(
        find.text('You have not exported your data recently.'),
        findsNothing,
      );
      expect(find.text('Export first'), findsNothing);
    });

    testWidgets('Delete All empties the list and shows the empty state', (
      tester,
    ) async {
      final provider = await pumpHistory(tester, records: threeRecords);
      await openClearDialog(tester);

      await tester.tap(find.text('Delete All'));
      await tester.pump();
      await settleIo(tester);

      expect(find.text('Clear All Scan Records?'), findsNothing);
      expect(find.text('All scan records deleted'), findsOneWidget);
      expect(find.byType(HistoryCard), findsNothing);
      expect(find.text('No scans yet'), findsOneWidget);
      expect(find.text('EMPTY LOG'), findsOneWidget);
      expect(provider.totalCount, 0);
      expect(await tester.runAsync(db.count), 0);
      expect(find.text('Clear all coming soon'), findsNothing);
    });

    testWidgets('a failed delete shows the error message and keeps data', (
      tester,
    ) async {
      final provider = await pumpHistory(tester, records: threeRecords);
      await openClearDialog(tester);
      db.failDelete = true;

      await tester.tap(find.text('Delete All'));
      await tester.pump();
      await settleIo(tester);

      expect(
        find.text('Could not delete records. Please try again.'),
        findsOneWidget,
      );
      expect(find.byType(HistoryCard), findsNWidgets(3));
      expect(provider.totalCount, 3);
    });

    testWidgets('Export first closes the dialog and exports', (tester) async {
      await pumpHistory(tester, records: threeRecords);
      await openClearDialog(tester);

      await tester.tap(find.text('Export first'));
      await tester.pump();
      await settleIo(tester);

      expect(find.text('Clear All Scan Records?'), findsNothing);
      expect(shared.length, 1);
      expect(find.byType(HistoryCard), findsNWidgets(3)); // nothing deleted
    });

    testWidgets('the delete icon is hidden in the empty state', (tester) async {
      await pumpHistory(tester);
      expect(find.byTooltip('Clear all'), findsNothing);
    });
  });

  group('no overflow at text scale 1.3 on a 5 inch phone', () {
    const phone = Size(360, 640);

    testWidgets('clear dialog with the warning', (tester) async {
      await pumpHistory(
        tester,
        records: threeRecords,
        textScale: 1.3,
        size: phone,
      );
      await openClearDialog(tester);

      expect(find.text('Clear All Scan Records?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('low storage dialog', (tester) async {
      freeBehaviour = () async => 1024;
      await pumpHistory(
        tester,
        records: threeRecords,
        textScale: 1.3,
        size: phone,
      );
      await tester.tap(find.byTooltip('Export').first);
      await tester.pump();
      await settleIo(tester);

      expect(find.text('Low storage'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('history with records', (tester) async {
      await pumpHistory(
        tester,
        records: threeRecords,
        textScale: 1.3,
        size: phone,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
