import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a non-GS1 scan warns, Save Anyway stores it as ALERT', (
    tester,
  ) async {
    final harness = await AppHarness.create();
    addTearDown(harness.dispose);
    await harness.launch(tester);
    await openScanScreen(tester);

    await harness.detect(tester, 'https://example.com', format: 'qrCode');
    await pumpUntilFound(tester, find.text('Unrecognised barcode format'));

    // Nothing is saved until the user decides.
    expect(find.textContaining('Not saved yet'), findsOneWidget);
    expect(find.text('Save Anyway'), findsOneWidget);
    expect(find.text('Rescan'), findsOneWidget);
    expect(await harness.db.count(), 0);

    // The buttons sit at the end of a scrollable sheet that is still sliding
    // in; taps during a route transition are ignored.
    await settle(tester, 500);
    await tester.ensureVisible(find.text('Save Anyway'));
    await tester.pump();
    await tester.tap(find.text('Save Anyway'));
    await pumpUntilFound(tester, find.text('Saved with warnings'));
    expect(await harness.db.count(), 1);

    await tester.tap(find.byTooltip('Back').first);
    await pumpUntilFound(tester, find.text('Total Scans'));
    await tester.tap(find.text('Scan History'));
    await pumpUntilFound(tester, find.text('Scan Log Details'));
    await pumpUntilFound(tester, find.text('ALERT'));

    expect(find.text('Unrecognised barcode'), findsOneWidget);
    expect(find.text('PASS'), findsNothing);
  });

  testWidgets('Rescan on the warning sheet stores nothing', (tester) async {
    final harness = await AppHarness.create();
    addTearDown(harness.dispose);
    await harness.launch(tester);
    await openScanScreen(tester);

    await harness.detect(tester, 'not-a-gs1-code', format: 'qrCode');
    await pumpUntilFound(tester, find.text('Rescan'));
    await settle(tester, 500);
    await tester.ensureVisible(find.text('Rescan'));
    await tester.pump();
    await tester.tap(find.text('Rescan'));
    await pumpUntilGone(tester, find.text('Save Anyway'));

    expect(await harness.db.count(), 0);
  });
}
