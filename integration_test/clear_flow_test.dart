import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Clear All asks first, then empties the history', (tester) async {
    final harness = await AppHarness.create();
    addTearDown(harness.dispose);
    await harness.seed([for (var i = 0; i < 3; i++) sampleRecord(i)]);
    await harness.launch(tester);

    await tester.tap(find.text('Scan History'));
    await pumpUntilFound(tester, find.text('Scan Log Details'));
    await pumpUntilFound(tester, find.text('3 records logged'));

    await tester.tap(find.byTooltip('Clear all'));
    await pumpUntilFound(tester, find.text('Clear All Scan Records?'));
    expect(
      find.textContaining('permanently delete all 3 stored scan records.'),
      findsOneWidget,
    );
    // Never exported, so the warning is shown.
    expect(
      find.text('You have not exported your data recently.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Delete All'));
    await pumpUntilFound(tester, find.text('All scan records deleted'));
    await pumpUntilFound(tester, find.text('No scans yet'));

    // The list fades out before it leaves the tree.
    await pumpUntilGone(tester, find.text('SEED-0'));
    expect(find.text('EMPTY LOG'), findsOneWidget);
    expect(await harness.db.count(), 0);

    // Home agrees.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await pumpUntilFound(tester, find.text('Total Scans'));
    await pumpUntilFound(tester, find.text('0'));
    expect(find.text('—'), findsOneWidget);
  });
}
