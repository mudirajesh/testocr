import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/providers/history_provider.dart';
import 'package:gs1scan/screens/history_screen.dart';
import 'package:gs1scan/services/database_service.dart';
import 'package:gs1scan/widgets/history_card.dart';
import 'package:gs1scan/widgets/scan_result_sheet.dart';
import 'package:provider/provider.dart';

import 'support/spy_db.dart';

ScanRecord rec(
  String id, {
  String? batch,
  String? gtin,
  bool isValid = true,
  String format = 'DataMatrix',
  int minute = 0,
}) => ScanRecord(
  id: id,
  rawBarcode: 'raw-$id',
  barcodeFormat: format,
  batchNumber: batch,
  gtin: gtin,
  expiryDate: '271231',
  scanTimestamp: DateTime(2026, 9, 29, 10, minute),
  confidenceScore: 1.0,
  isValid: isValid,
);

void main() {
  late SpyDb db;

  setUp(() => db = SpyDb());

  /// Seeds [records], loads the provider in real time and pumps the screen.
  Future<HistoryProvider> pumpHistory(
    WidgetTester tester, {
    List<ScanRecord> records = const [],
    double textScale = 1.0,
    Size size = const Size(400, 800),
    bool failReads = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => tester.runAsync(db.close));

    final provider = HistoryProvider(
      db,
      searchDebounce: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);

    await tester.runAsync(() async {
      await db.insertAll(records);
      db.failReads = failReads;
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

  /// Lets real database I/O finish, then renders the result.
  Future<void> settleDb(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // The first pump builds the new state and starts AnimatedSwitcher's fade;
    // the second lets it finish and drop the old child.
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('shows cards from real records with PASS and ALERT badges', (
    tester,
  ) async {
    await pumpHistory(
      tester,
      records: [
        rec('a', batch: 'BN-A', gtin: '08901234567890', minute: 3),
        rec('b', batch: 'LOT-B', isValid: false, minute: 2),
        rec('c', isValid: false, minute: 1),
      ],
    );

    expect(find.byType(HistoryCard), findsNWidgets(3));
    expect(find.text('BN-A'), findsOneWidget);
    expect(find.text('LOT-B'), findsOneWidget);
    expect(find.text('PASS'), findsOneWidget);
    expect(find.text('ALERT'), findsNWidgets(2));
    expect(find.text('GTIN: 08901234567890'), findsOneWidget);
    expect(find.text('29 Sep 2026, 10:03'), findsOneWidget);
    expect(find.text('3 records logged'), findsOneWidget);
    // Mock data is gone.
    expect(find.text('LOT-A2B459X'), findsNothing);
  });

  testWidgets('null batch shows Unrecognised barcode, MANUAL shows Manual '
      'entry', (tester) async {
    await pumpHistory(
      tester,
      records: [
        rec('n', isValid: false, minute: 2),
        rec('m', batch: 'MB-1', format: 'MANUAL', minute: 1),
      ],
    );

    expect(find.text('Unrecognised barcode'), findsOneWidget);
    expect(find.text('GTIN: Not found'), findsOneWidget);
    expect(find.text('Manual entry'), findsOneWidget);
    expect(find.text('MB-1'), findsOneWidget);
  });

  testWidgets('cards expose a semantics label', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpHistory(
      tester,
      records: [rec('a', batch: 'BN2024X981', gtin: '08901234567890')],
    );
    expect(
      find.bySemanticsLabel('BN2024X981, pass, scanned 29 Sep 2026 10:00'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('an empty database shows the empty state', (tester) async {
    await pumpHistory(tester);

    expect(find.text('No scans yet'), findsOneWidget);
    expect(find.text('Start Scanning'), findsOneWidget);
    expect(find.text('0 records'), findsOneWidget);
    expect(find.text('EMPTY LOG'), findsOneWidget);
    expect(find.byType(HistoryCard), findsNothing);
  });

  testWidgets('a search with no results shows No matches and Clear search '
      'restores the list', (tester) async {
    final provider = await pumpHistory(
      tester,
      records: [
        rec('a', batch: 'BN-A', minute: 2),
        rec('b', batch: 'BN-B', minute: 1),
      ],
    );

    // Open the inline search and type.
    await tester.tap(find.byTooltip('Search').last);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump(const Duration(milliseconds: 30)); // debounce fires
    await settleDb(tester);

    expect(provider.searchQuery, 'zzz');
    expect(find.text('No matches'), findsOneWidget);
    expect(find.byType(HistoryCard), findsNothing);

    await tester.tap(find.text('Clear search'));
    await tester.pump();
    await settleDb(tester);

    expect(provider.searchQuery, isEmpty);
    expect(find.text('No matches'), findsNothing);
    expect(find.byType(HistoryCard), findsNWidgets(2));
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('searching filters the list and shows the match count', (
    tester,
  ) async {
    await pumpHistory(
      tester,
      records: [
        rec('a', batch: 'BN-A', minute: 3),
        rec('b', batch: 'BN-B', minute: 2),
        rec('c', batch: 'XYZ', minute: 1),
      ],
    );

    await tester.tap(find.byTooltip('Search').last);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'bn-');
    await tester.pump(const Duration(milliseconds: 30));
    await settleDb(tester);

    expect(find.byType(HistoryCard), findsNWidgets(2));
    expect(find.text('2 results'), findsOneWidget);
  });

  testWidgets('tapping a card opens the detail sheet for that record', (
    tester,
  ) async {
    await pumpHistory(
      tester,
      records: [
        rec('a', batch: 'BN-A', gtin: '08901234567890', minute: 2),
        rec('b', batch: 'BN-B', minute: 1),
      ],
    );

    await tester.tap(find.text('BN-B'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ScanResultSheet), findsOneWidget);
    expect(find.text('Scan Details'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ScanResultSheet),
        matching: find.text('BN-B'),
      ),
      findsOneWidget,
    );
    expect(find.text('Close'), findsOneWidget);
    // Detail mode is read-only: no Done / Save buttons.
    expect(find.text('Save Anyway'), findsNothing);

    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ScanResultSheet), findsNothing);
  });

  testWidgets('scrolling near the bottom loads the next page', (tester) async {
    final provider = await pumpHistory(tester, records: seedRecords(120));
    expect(provider.records.length, 50);
    expect(find.text('120 records logged'), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pump();
      await settleDb(tester);
    }
    expect(provider.records.length, 100);

    for (var i = 0; i < 3; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pump();
      await settleDb(tester);
    }
    expect(provider.records.length, 120);
    expect(provider.hasMore, isFalse);
  });

  testWidgets('a failed first load shows Could not load scans and retry '
      'recovers', (tester) async {
    final provider = await pumpHistory(
      tester,
      records: [rec('a', batch: 'BN-A')],
      failReads: true,
    );

    expect(find.text('Could not load scans'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    db.failReads = false;
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await settleDb(tester);

    expect(provider.error, isNull);
    expect(find.text('Could not load scans'), findsNothing);
    expect(find.text('BN-A'), findsOneWidget);
  });

  group('no overflow at text scale 1.3', () {
    const phone = Size(360, 640);

    testWidgets('with records', (tester) async {
      await pumpHistory(
        tester,
        records: [
          rec(
            'a',
            batch: 'VERY-LONG-BATCH-NUMBER-1234',
            gtin: '08901234567890',
            minute: 3,
          ),
          rec('b', isValid: false, minute: 2),
          rec('c', batch: 'MB-1', format: 'MANUAL', minute: 1),
        ],
        textScale: 1.3,
        size: phone,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty state', (tester) async {
      await pumpHistory(tester, textScale: 1.3, size: phone);
      expect(tester.takeException(), isNull);
      expect(find.text('No scans yet'), findsOneWidget);
    });

    testWidgets('no matches', (tester) async {
      await pumpHistory(
        tester,
        records: [rec('a', batch: 'BN-A')],
        textScale: 1.3,
        size: phone,
      );
      await tester.tap(find.byTooltip('Search').last);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump(const Duration(milliseconds: 30));
      await settleDb(tester);
      expect(find.text('No matches'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
