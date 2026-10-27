import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Home -> scan -> success sheet -> Home stats -> History -> '
      'detail', (tester) async {
    final harness = await AppHarness.create();
    addTearDown(harness.dispose);
    await harness.launch(tester);

    // Home starts empty.
    expect(find.text('Total Scans'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);

    await openScanScreen(tester);

    // Three agreeing frames of a valid GS1 DataMatrix.
    await harness.detect(tester, validGs1);
    await pumpUntilFound(tester, find.text('Scan Successful'));

    expect(find.text('BN2024X981'), findsWidgets);
    expect(find.text('08901234567890'), findsOneWidget);
    expect(find.text('31/12/2026'), findsOneWidget);
    expect(find.textContaining('Saved to history'), findsOneWidget);

    // Done keeps the scanner running; Back returns to Home.
    await tester.tap(find.text('Done'));
    await pumpUntilGone(tester, find.text('Scan Successful'));
    await pumpUntilFound(tester, find.text('Scanning...'));
    await tester.tap(find.byTooltip('Back').first);
    await pumpUntilFound(tester, find.text('Total Scans'));

    // Home shows the new total.
    await pumpUntilFound(tester, find.text('1'));
    expect(find.text('Just now'), findsOneWidget);

    // History lists it, and tapping the card opens the detail sheet.
    await tester.tap(find.text('Scan History'));
    await pumpUntilFound(tester, find.text('Scan Log Details'));
    await pumpUntilFound(tester, find.text('BN2024X981'));
    expect(find.text('PASS'), findsOneWidget);

    await tester.tap(find.text('BN2024X981'));
    await pumpUntilFound(tester, find.text('Scan Details'));
    expect(find.text('Close'), findsOneWidget);
    expect(find.text('31/12/2026'), findsOneWidget);
  });
}
