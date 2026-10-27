import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Scan -> keyboard button -> save a batch -> History shows '
      'Manual entry', (tester) async {
    final harness = await AppHarness.create();
    addTearDown(harness.dispose);
    await harness.launch(tester);
    await openScanScreen(tester);

    await tester.tap(find.byTooltip('Manual entry'));
    await pumpUntilFound(tester, find.text('Save Entry'));
    // The camera is paused while manual entry is open.
    expect(harness.source.pauseCalls, greaterThan(0));

    await tester.enterText(find.byType(TextField).first, 'BN2024X981');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Save Entry'));

    // Back on the scan screen with a confirmation; the camera is running again.
    await pumpUntilFound(tester, find.text('Manual entry saved'));
    expect(harness.source.resumeCalls, greaterThan(0));
    expect(await harness.db.count(), 1);

    // Wait for manual entry to finish leaving before tapping the scan screen's
    // own back button (both have a 'Back' tooltip).
    await pumpUntilGone(tester, find.text('Save Entry'));
    await settle(tester, 500); // taps during a route transition are ignored
    await tester.tap(find.byTooltip('Back').first);
    await pumpUntilFound(tester, find.text('Total Scans'));
    await tester.tap(find.text('Scan History'));
    await pumpUntilFound(tester, find.text('Scan Log Details'));
    await pumpUntilFound(tester, find.text('BN2024X981'));

    expect(find.text('Manual entry'), findsOneWidget);
    expect(find.text('PASS'), findsOneWidget);
  });
}
