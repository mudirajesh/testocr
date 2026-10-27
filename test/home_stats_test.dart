import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/providers/history_provider.dart';
import 'package:gs1scan/screens/home_screen.dart';
import 'package:gs1scan/services/camera_availability.dart';
import 'package:gs1scan/services/database_service.dart';
import 'package:provider/provider.dart';

import 'support/spy_db.dart';

class _HasCamera implements CameraAvailability {
  @override
  Future<bool> hasCamera() async => true;
}

void main() {
  late SpyDb db;
  late HistoryProvider provider;

  setUp(() {
    db = SpyDb();
    provider = HistoryProvider(db);
  });

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(provider.dispose);
    addTearDown(() => tester.runAsync(db.close));

    await tester.runAsync(provider.loadInitial);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<DatabaseService>.value(value: db),
          ChangeNotifierProvider<HistoryProvider>.value(value: provider),
          ChangeNotifierProvider<CameraAvailabilityProvider>(
            create: (_) => CameraAvailabilityProvider(_HasCamera()),
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('shows 0 and a dash when there are no scans', (tester) async {
    await pumpHome(tester);

    expect(find.text('Total Scans'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('Last Scan'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    // The old mock values are gone.
    expect(find.text('142'), findsNothing);
    expect(find.text('2h ago'), findsNothing);
  });

  testWidgets('shows the real count and relative time after a scan is '
      'saved', (tester) async {
    await pumpHome(tester);

    await tester.runAsync(() async {
      await db.insert(
        ScanRecord(
          id: 'new',
          rawBarcode: 'x',
          barcodeFormat: 'DataMatrix',
          batchNumber: 'BN1',
          scanTimestamp: DateTime.now(),
        ),
      );
      await provider.refresh(); // what ScannerProvider.onRecordSaved does
    });
    await tester.pump();

    expect(find.text('1'), findsOneWidget);
    expect(find.text('Just now'), findsOneWidget);
    expect(find.text('—'), findsNothing);
  });

  testWidgets('older scans show a relative age', (tester) async {
    await tester.runAsync(
      () => db.insert(
        ScanRecord(
          id: 'old',
          rawBarcode: 'x',
          barcodeFormat: 'DataMatrix',
          batchNumber: 'BN1',
          scanTimestamp: DateTime.now().subtract(const Duration(hours: 2)),
        ),
      ),
    );
    await pumpHome(tester);

    expect(find.text('2h ago'), findsOneWidget);
  });
}
