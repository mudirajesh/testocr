import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/main.dart';
import 'package:gs1scan/services/camera_availability.dart';

import 'support/fakes.dart';

class _HasCamera implements CameraAvailability {
  @override
  Future<bool> hasCamera() async => true;
}

void main() {
  testWidgets('App builds, shows the splash and then Home', (tester) async {
    await tester.pumpWidget(
      buildApp(
        source: FakeBarcodeSource(),
        db: FakeDb(),
        cameraAvailability: _HasCamera(),
      ),
    );
    expect(find.text('GS1 Scan'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Scan Barcode'), findsOneWidget);
    expect(find.text('Total Scans'), findsOneWidget);
  });
}
