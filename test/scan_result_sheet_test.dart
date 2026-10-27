import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/utils/batch_highlight.dart';
import 'package:gs1scan/widgets/scan_result_sheet.dart';

ScanRecord record({
  String? batch = 'BN2024X981',
  String? gtin = '08901234567890',
  String? expiry = '261231',
  String? serial,
  double? confidence = 1.0,
  bool isValid = true,
  String raw = '01089012345678901726123110BN2024X981',
  String format = 'DataMatrix',
}) => ScanRecord(
  id: 'id-1',
  rawBarcode: raw,
  barcodeFormat: format,
  batchNumber: batch,
  gtin: gtin,
  expiryDate: expiry,
  serialNumber: serial,
  scanTimestamp: DateTime(2026, 9, 29, 14, 32, 5),
  confidenceScore: confidence,
  isValid: isValid,
);

void main() {
  ScanSheetAction? lastAction;

  /// Opens the sheet from a button, on a phone-sized surface.
  Future<void> openSheet(
    WidgetTester tester,
    ScanRecord rec, {
    ScanSheetMode mode = ScanSheetMode.success,
    List<String> issues = const [],
    bool saveFailed = false,
    String? title,
    double textScale = 1.0,
    Size size = const Size(400, 1600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    lastAction = null;

    // Unmount anything left over from an earlier open() in the same test.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
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
                  lastAction = await showScanResultSheet(
                    context,
                    rec,
                    mode: mode,
                    issues: issues,
                    saveFailed: saveFailed,
                    title: title,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('success mode', () {
    testWidgets('shows batch, GTIN, formatted expiry and Saved to history', (
      tester,
    ) async {
      await openSheet(tester, record());

      expect(find.text('Scan Successful'), findsOneWidget);
      expect(find.textContaining('Saved to history'), findsOneWidget);
      expect(find.textContaining('DataMatrix'), findsWidgets);
      expect(find.text('BN2024X981'), findsOneWidget);
      expect(find.text('08901234567890'), findsOneWidget);
      expect(find.text('31/12/2026'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Rescan'), findsNothing);
    });

    testWidgets('serial row is hidden when null and shown when present', (
      tester,
    ) async {
      await openSheet(tester, record());
      expect(find.text('Serial Number'), findsNothing);

      await openSheet(tester, record(serial: 'SER-42'));
      expect(find.text('Serial Number'), findsOneWidget);
      expect(find.text('SER-42'), findsOneWidget);
    });

    testWidgets('Done returns ScanSheetAction.done', (tester) async {
      await openSheet(tester, record());
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(lastAction, ScanSheetAction.done);
    });

    testWidgets('a barrier tap dismisses it', (tester) async {
      await openSheet(tester, record());
      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(find.text('Scan Successful'), findsNothing);
      expect(lastAction, ScanSheetAction.dismissed);
    });

    testWidgets('missing values show a dash', (tester) async {
      await openSheet(tester, record(batch: null, gtin: null, expiry: null));
      expect(find.text('—'), findsNWidgets(3));
    });

    testWidgets('an unreadable expiry is shown raw and flagged invalid', (
      tester,
    ) async {
      await openSheet(tester, record(expiry: '261301'));
      expect(find.textContaining('261301'), findsOneWidget);
      expect(find.textContaining('(invalid)'), findsOneWidget);
    });

    testWidgets('title can be overridden', (tester) async {
      await openSheet(tester, record(), title: 'Custom title');
      expect(find.text('Custom title'), findsOneWidget);
      expect(find.text('Scan Successful'), findsNothing);
    });
  });

  group('O/0 hint', () {
    testWidgets('shown for a batch containing O or 0', (tester) async {
      await openSheet(tester, record(batch: 'BO2024O98'));
      expect(find.textContaining('Highlighted characters'), findsOneWidget);
    });

    testWidgets('absent for a batch with neither', (tester) async {
      await openSheet(tester, record(batch: 'BNX9'));
      expect(find.textContaining('Highlighted characters'), findsNothing);
    });

    test('ambiguousBatchPositions finds O, o and 0', () {
      expect(ambiguousBatchPositions('BO2024O98'), [1, 3, 6]);
      expect(ambiguousBatchPositions('BNX9'), isEmpty);
      expect(ambiguousBatchPositions('o1'), [0]);
    });
  });

  group('warning mode', () {
    testWidgets('is not dismissible and lists issues and both buttons', (
      tester,
    ) async {
      await openSheet(
        tester,
        record(isValid: false, confidence: 0.6),
        mode: ScanSheetMode.warning,
        issues: const ['GTIN check digit invalid', 'Duplicate AI 10'],
      );

      expect(find.textContaining('Not saved yet'), findsOneWidget);
      expect(find.text('GTIN check digit invalid'), findsOneWidget);
      expect(find.text('Duplicate AI 10'), findsOneWidget);
      expect(find.text('Rescan'), findsOneWidget);
      expect(find.text('Save Anyway'), findsOneWidget);
      expect(find.text('Done'), findsNothing);

      // Barrier tap and back must not close it.
      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(find.text('Save Anyway'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Save Anyway'), findsOneWidget);
      expect(lastAction, isNull);
    });

    testWidgets('Rescan returns ScanSheetAction.rescan', (tester) async {
      await openSheet(
        tester,
        record(isValid: false),
        mode: ScanSheetMode.warning,
      );
      await tester.tap(find.text('Rescan'));
      await tester.pumpAndSettle();
      expect(lastAction, ScanSheetAction.rescan);
    });

    testWidgets('Save Anyway returns ScanSheetAction.saveAnyway', (
      tester,
    ) async {
      await openSheet(
        tester,
        record(isValid: false),
        mode: ScanSheetMode.warning,
      );
      await tester.tap(find.text('Save Anyway'));
      await tester.pumpAndSettle();
      expect(lastAction, ScanSheetAction.saveAnyway);
    });

    testWidgets('title depends on the case', (tester) async {
      await openSheet(
        tester,
        record(batch: null, gtin: null, expiry: null, raw: 'https://x.io'),
        mode: ScanSheetMode.warning,
      );
      expect(find.text('Unrecognised barcode format'), findsOneWidget);

      await openSheet(
        tester,
        record(isValid: false, confidence: 0.2),
        mode: ScanSheetMode.warning,
      );
      expect(find.text('Low confidence scan'), findsOneWidget);

      await openSheet(
        tester,
        record(isValid: false, confidence: 0.6),
        mode: ScanSheetMode.warning,
      );
      expect(find.text('Check this scan'), findsOneWidget);
    });

    testWidgets('more than 4 issues collapse behind Show all', (tester) async {
      await openSheet(
        tester,
        record(isValid: false),
        mode: ScanSheetMode.warning,
        issues: [for (var i = 1; i <= 6; i++) 'Issue $i'],
      );
      expect(find.text('Issue 4'), findsOneWidget);
      expect(find.text('Issue 5'), findsNothing);

      await tester.tap(find.text('Show all (6)'));
      await tester.pumpAndSettle();
      expect(find.text('Issue 6'), findsOneWidget);
      expect(find.text('Show less'), findsOneWidget);
    });

    testWidgets('saveFailed shows the banner and Retry Save', (tester) async {
      await openSheet(
        tester,
        record(isValid: false),
        mode: ScanSheetMode.warning,
        saveFailed: true,
      );
      expect(find.text('Could not save this scan. Try again.'), findsOneWidget);
      expect(find.text('Retry Save'), findsOneWidget);
      expect(find.text('Save Anyway'), findsNothing);

      await tester.tap(find.text('Retry Save'));
      await tester.pumpAndSettle();
      expect(lastAction, ScanSheetAction.saveAnyway);
    });

    testWidgets('no banner without a failed save', (tester) async {
      await openSheet(
        tester,
        record(isValid: false),
        mode: ScanSheetMode.warning,
      );
      expect(find.textContaining('Could not save'), findsNothing);
    });
  });

  group('detail mode', () {
    testWidgets('shows format only and a Close button', (tester) async {
      await openSheet(tester, record(), mode: ScanSheetMode.detail);
      expect(find.textContaining('Saved to history'), findsNothing);
      expect(find.textContaining('Not saved yet'), findsNothing);
      expect(find.text('Close'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(lastAction, ScanSheetAction.close);
    });

    testWidgets('uses the warning icon for an invalid record', (tester) async {
      await openSheet(
        tester,
        record(isValid: false),
        mode: ScanSheetMode.detail,
      );
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });
  });

  group('raw barcode and confidence', () {
    testWidgets('raw string is collapsed and shows <GS> when expanded', (
      tester,
    ) async {
      const raw = '0108901234567890\u001D10BN2024X981';
      await openSheet(tester, record(raw: raw));

      expect(find.text('Raw Barcode String'), findsOneWidget);
      expect(find.textContaining('<GS>'), findsNothing);

      await tester.tap(find.text('Raw Barcode String'));
      await tester.pumpAndSettle();
      expect(find.textContaining('<GS>'), findsOneWidget);
      // Display only: the stored value keeps the real control character.
      expect(raw.contains('\u001D'), isTrue);
      expect(visibleRaw(raw), '0108901234567890<GS>10BN2024X981');
    });

    testWidgets('confidence chip is hidden when there is no score', (
      tester,
    ) async {
      await openSheet(tester, record(confidence: null));
      expect(find.text('Confidence'), findsNothing);
    });

    testWidgets('confidence chip shows the percentage', (tester) async {
      await openSheet(tester, record(confidence: 0.6));
      expect(find.text('Confidence'), findsOneWidget);
      expect(find.text('60%'), findsOneWidget);
    });
  });

  group('layout', () {
    const phone = Size(360, 640);

    for (final mode in ScanSheetMode.values) {
      testWidgets('no overflow at text scale 1.3 in $mode mode', (
        tester,
      ) async {
        await openSheet(
          tester,
          record(
            batch: 'BO2024O98-LONGER',
            serial: 'SERIAL-1234567890',
            expiry: '261301',
            confidence: 0.6,
            isValid: false,
            raw: '01089012345678901726130110BO2024O98-LONGER\u001D21SERIAL-1234567890',
          ),
          mode: mode,
          issues: [
            'Low confidence: only 2 of 5 frames agreed',
            'GTIN check digit invalid',
            'Batch contains characters that can be confused (O/0)',
            'AI 17: invalid date',
            'Duplicate AI 10',
          ],
          saveFailed: mode == ScanSheetMode.warning,
          textScale: 1.3,
          size: phone,
        );

        expect(tester.takeException(), isNull);

        // Expand the raw section and scroll everything into view.
        await tester.ensureVisible(find.text('Raw Barcode String'));
        await tester.tap(find.text('Raw Barcode String'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
