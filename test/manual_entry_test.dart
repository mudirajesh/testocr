import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/providers/history_provider.dart';
import 'package:gs1scan/screens/history_screen.dart';
import 'package:gs1scan/screens/manual_entry_screen.dart';
import 'package:gs1scan/services/database_service.dart';
import 'package:provider/provider.dart';

import 'support/spy_db.dart';

void main() {
  late SpyDb db;
  late HistoryProvider provider;
  bool? popResult;

  setUp(() {
    db = SpyDb();
    popResult = null;
  });

  /// Opens the screen from a home page so that pop and the discard dialog
  /// behave as they do in the app.
  Future<void> pumpManual(
    WidgetTester tester, {
    double textScale = 1.0,
    Size size = const Size(400, 900),
    bool openFromRoute = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => tester.runAsync(db.close));

    provider = HistoryProvider(
      db,
      searchDebounce: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);
    await tester.runAsync(provider.loadInitial);

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
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    popResult = await Navigator.of(context).push<bool>(
                      MaterialPageRoute<bool>(
                        builder: (_) => const ManualEntryScreen(),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Alternates real I/O with pumps so a chain of database calls completes.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  Finder batchField() => find.byType(TextField).first;
  Finder gtinField() => find.byType(TextField).last;

  Future<List<ScanRecord>> stored(WidgetTester tester) async =>
      (await tester.runAsync(() => db.getAll()))!;

  group('layout', () {
    testWidgets('shows the title, intro, fields and Save Entry', (
      tester,
    ) async {
      await pumpManual(tester);

      expect(find.text('Manual Entry'), findsOneWidget);
      expect(
        find.text('Type the batch number if the barcode cannot be scanned.'),
        findsOneWidget,
      );
      expect(find.text('Batch Number'), findsOneWidget);
      expect(find.text('GTIN (optional)'), findsOneWidget);
      expect(find.text('Save Entry'), findsOneWidget);
      expect(find.text('0/20'), findsOneWidget);
    });
  });

  group('batch validation', () {
    testWidgets('an empty batch is blocked', (tester) async {
      await pumpManual(tester);

      await tester.tap(find.text('Save Entry'));
      await tester.pump();

      expect(find.text('Enter a batch number'), findsOneWidget);
      expect(await stored(tester), isEmpty);
    });

    testWidgets('whitespace only counts as empty', (tester) async {
      await pumpManual(tester);

      await tester.enterText(batchField(), '   ');
      await tester.tap(find.text('Save Entry'));
      await tester.pump();

      expect(find.text('Enter a batch number'), findsOneWidget);
      expect(await stored(tester), isEmpty);
    });

    testWidgets('21 characters are blocked, 20 are accepted', (tester) async {
      await pumpManual(tester);

      await tester.enterText(batchField(), 'A' * 21);
      await tester.pump();
      expect(find.text('21/20'), findsOneWidget);
      await tester.tap(find.text('Save Entry'));
      await tester.pump();
      expect(
        find.text('Batch number can be at most 20 characters'),
        findsOneWidget,
      );
      expect(await stored(tester), isEmpty);

      await tester.enterText(batchField(), 'A' * 20);
      await tester.tap(find.text('Save Entry'));
      await tester.pump();
      await settleIo(tester);
      expect((await stored(tester)).length, 1);
    });

    testWidgets('the error clears when the user edits the field', (
      tester,
    ) async {
      await pumpManual(tester);
      await tester.tap(find.text('Save Entry'));
      await tester.pump();
      expect(find.text('Enter a batch number'), findsOneWidget);

      await tester.enterText(batchField(), 'B');
      await tester.pump();
      expect(find.text('Enter a batch number'), findsNothing);
    });

    testWidgets('unusual characters only warn, never block', (tester) async {
      await pumpManual(tester);

      await tester.enterText(batchField(), 'LOT/2024');
      await tester.pump();
      expect(find.textContaining('unusual characters'), findsOneWidget);

      await tester.tap(find.text('Save Entry'));
      await tester.pump();
      await settleIo(tester);
      expect((await stored(tester)).single.batchNumber, 'LOT/2024');
    });
  });

  group('saving', () {
    testWidgets('a valid batch is saved as a MANUAL record and pops true', (
      tester,
    ) async {
      await pumpManual(tester);

      await tester.enterText(batchField(), 'BN2024X981');
      await tester.tap(find.text('Save Entry'));
      await tester.pump();
      await settleIo(tester);

      final record = (await stored(tester)).single;
      expect(record.barcodeFormat, 'MANUAL');
      expect(record.batchNumber, 'BN2024X981');
      expect(record.rawBarcode, 'BN2024X981');
      expect(record.gtin, isNull);
      expect(record.confidenceScore, isNull);
      expect(record.isValid, isTrue);

      expect(find.text('Manual Entry'), findsNothing); // popped
      expect(popResult, isTrue);
      expect(provider.totalCount, 1); // History refreshed
    });

    testWidgets('the typed value is stored exactly, only trimmed', (
      tester,
    ) async {
      await pumpManual(tester);

      await tester.enterText(batchField(), '  Lot-ab/1_x o0  ');
      await tester.tap(find.text('Save Entry'));
      await tester.pump();
      await settleIo(tester);

      expect((await stored(tester)).single.batchNumber, 'Lot-ab/1_x o0');
    });

    testWidgets('the record appears in History with Manual entry', (
      tester,
    ) async {
      await pumpManual(tester);
      await tester.enterText(batchField(), 'BN-HAND-1');
      await tester.tap(find.text('Save Entry'));
      await tester.pump();
      await settleIo(tester);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<DatabaseService>.value(value: db),
            ChangeNotifierProvider<HistoryProvider>.value(value: provider),
          ],
          child: const MaterialApp(home: HistoryScreen()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('BN-HAND-1'), findsOneWidget);
      expect(find.text('Manual entry'), findsOneWidget);
      expect(find.text('PASS'), findsOneWidget);
      expect(find.text('ALERT'), findsNothing);
    });

    testWidgets('manual entries are not de-duplicated', (tester) async {
      await pumpManual(tester);
      for (var i = 0; i < 2; i++) {
        await tester.enterText(batchField(), 'SAME-BATCH');
        await tester.tap(find.text('Save Entry'));
        await tester.pump();
        await settleIo(tester);
        if (i == 0) {
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
        }
      }
      expect((await stored(tester)).length, 2);
    });

    testWidgets('a failed save shows a message and stays on the screen', (
      tester,
    ) async {
      await pumpManual(tester);
      db.failInsert = true;

      await tester.enterText(batchField(), 'BN1');
      await tester.tap(find.text('Save Entry'));
      await tester.pump();
      await settleIo(tester);

      expect(find.text('Could not save. Please try again.'), findsOneWidget);
      expect(find.text('Manual Entry'), findsWidgets);
      expect(find.text('Save Entry'), findsOneWidget); // not stuck saving
      expect(popResult, isNull);

      // The text is still there and a retry works.
      db.failInsert = false;
      await tester.tap(find.text('Save Entry'));
      await tester.pump();
      await settleIo(tester);
      expect((await stored(tester)).single.batchNumber, 'BN1');
    });
  });

  group('GTIN', () {
    testWidgets('a wrong check digit is blocked', (tester) async {
      await pumpManual(tester);

      await tester.enterText(batchField(), 'BN1');
      await tester.enterText(gtinField(), '08901234567891');
      await tester.tap(find.text('Save Entry'));
      await tester.pump();

      expect(
        find.text('GTIN must be 14 digits with a valid check digit'),
        findsOneWidget,
      );
      expect(await stored(tester), isEmpty);
    });

    testWidgets('fewer than 14 digits is blocked', (tester) async {
      await pumpManual(tester);

      await tester.enterText(batchField(), 'BN1');
      await tester.enterText(gtinField(), '8901234567890');
      await tester.tap(find.text('Save Entry'));
      await tester.pump();

      expect(
        find.text('GTIN must be 14 digits with a valid check digit'),
        findsOneWidget,
      );
    });

    testWidgets('a valid GTIN is accepted and stored', (tester) async {
      await pumpManual(tester);

      await tester.enterText(batchField(), 'BN1');
      await tester.enterText(gtinField(), '08901234567890');
      await tester.tap(find.text('Save Entry'));
      await tester.pump();
      await settleIo(tester);

      expect((await stored(tester)).single.gtin, '08901234567890');
    });

    testWidgets('an empty GTIN is accepted and stored as null', (tester) async {
      await pumpManual(tester);

      await tester.enterText(batchField(), 'BN1');
      await tester.tap(find.text('Save Entry'));
      await tester.pump();
      await settleIo(tester);

      expect((await stored(tester)).single.gtin, isNull);
    });

    testWidgets('only digits can be typed', (tester) async {
      await pumpManual(tester);

      await tester.enterText(gtinField(), '08a9-01 23');
      await tester.pump();
      final field = tester.widget<TextField>(gtinField());
      expect(field.controller!.text, '0890123');
    });
  });

  group('O/0 hint', () {
    testWidgets('shown with a highlighted preview for BO2024', (tester) async {
      await pumpManual(tester);

      await tester.enterText(batchField(), 'BO2024');
      await tester.pump();

      expect(
        find.text('Check O (letter) vs 0 (zero) against the pack.'),
        findsOneWidget,
      );
      expect(find.text('Preview'), findsOneWidget);
      // Preview shows the same text, character by character.
      expect(find.text('BO2024'), findsNWidgets(2)); // field + preview
    });

    testWidgets('absent for BNX9', (tester) async {
      await pumpManual(tester);

      await tester.enterText(batchField(), 'BNX9');
      await tester.pump();

      expect(find.textContaining('Check O (letter)'), findsNothing);
      expect(find.text('Preview'), findsNothing);
    });
  });

  group('leaving the screen', () {
    testWidgets('typed text asks before discarding', (tester) async {
      await pumpManual(tester);
      await tester.enterText(batchField(), 'BN1');
      await tester.pump();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('Discard entry?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Discard entry?'), findsNothing);
      expect(find.text('Save Entry'), findsOneWidget);
      expect(await stored(tester), isEmpty);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Save Entry'), findsNothing); // left the screen
      expect(await stored(tester), isEmpty);
    });

    testWidgets('the system back button asks too', (tester) async {
      await pumpManual(tester);
      await tester.enterText(batchField(), 'BN1');
      await tester.pump();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard entry?'), findsOneWidget);
    });

    testWidgets('an empty form leaves without a question', (tester) async {
      await pumpManual(tester);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('Discard entry?'), findsNothing);
      expect(find.text('Save Entry'), findsNothing);
    });
  });

  group('no overflow at text scale 1.3 with the keyboard', () {
    testWidgets('with errors, hints and a 300 px keyboard inset', (
      tester,
    ) async {
      await pumpManual(tester, textScale: 1.3, size: const Size(360, 640));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);

      await tester.enterText(batchField(), 'BO2024/LOT_00');
      await tester.enterText(gtinField(), '123');
      await tester.ensureVisible(find.text('Save Entry'));
      await tester.pump();
      await tester.tap(find.text('Save Entry'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(
        find.text('GTIN must be 14 digits with a valid check digit'),
        findsOneWidget,
      );
    });

    testWidgets('empty form', (tester) async {
      await pumpManual(tester, textScale: 1.3, size: const Size(360, 640));
      expect(tester.takeException(), isNull);
    });
  });
}
