import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('export writes a BOM-prefixed CSV, shares it and confirms', (
    tester,
  ) async {
    final harness = await AppHarness.create();
    addTearDown(harness.dispose);
    await harness.seed([for (var i = 0; i < 3; i++) sampleRecord(i)]);
    await harness.launch(tester);

    await tester.tap(find.text('Scan History'));
    await pumpUntilFound(tester, find.text('Scan Log Details'));
    await pumpUntilFound(tester, find.text('SEED-0'));

    await tester.tap(find.byTooltip('Export').first);
    await pumpUntilFound(tester, find.text('CSV exported successfully'));

    expect(harness.shared.length, 1);
    final file = harness.shared.single;
    expect(
      file.path.split(Platform.pathSeparator).last,
      startsWith('gs1_scan_'),
    );
    expect(file.path, endsWith('.csv'));

    final bytes = await file.readAsBytes();
    expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
    final text = String.fromCharCodes(bytes.sublist(3));
    expect(text, startsWith('Sr. No.,Batch Number,GTIN'));
    expect(text, contains('SEED-0'));
    expect(text, contains('SEED-2'));
  });

  testWidgets('export with no records shows the empty message', (tester) async {
    final harness = await AppHarness.create();
    addTearDown(harness.dispose);
    await harness.launch(tester);

    await tester.tap(find.text('Scan History'));
    await pumpUntilFound(tester, find.text('Scan Log Details'));
    await pumpUntilFound(tester, find.text('No scans yet'));

    await tester.tap(find.byTooltip('Export').first);
    await pumpUntilFound(tester, find.text('No scan records to export'));
    expect(harness.shared, isEmpty);
  });
}
