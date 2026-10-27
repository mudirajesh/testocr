import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/widgets/camera_problem_view.dart';

void main() {
  var primary = 0;
  var manual = 0;
  var back = 0;

  setUp(() {
    primary = 0;
    manual = 0;
    back = 0;
  });

  Future<void> pumpView(
    WidgetTester tester,
    CameraProblemKind kind, {
    bool permanent = false,
    double textScale = 1.0,
    Size size = const Size(400, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: CameraProblemView(
          kind: kind,
          permanentlyDenied: permanent,
          onPrimary: () => primary++,
          onEnterManually: () => manual++,
          onBack: () => back++,
        ),
      ),
    );
  }

  group('permission needed', () {
    testWidgets('first denial offers Allow camera and manual entry', (
      tester,
    ) async {
      await pumpView(tester, CameraProblemKind.permission);

      expect(find.text('Camera permission needed'), findsOneWidget);
      expect(
        find.text(
          'GS1 Scan needs the camera to read pharmaceutical barcodes. '
          'Images never leave your device.',
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.camera_alt_outlined), findsOneWidget);
      expect(find.text('Allow camera'), findsOneWidget);
      expect(find.text('Open Settings'), findsNothing);
      expect(find.text('Enter batch manually'), findsOneWidget);

      await tester.tap(find.text('Allow camera'));
      await tester.tap(find.text('Enter batch manually'));
      expect(primary, 1);
      expect(manual, 1);
    });

    testWidgets('permanent denial shows Open Settings', (tester) async {
      await pumpView(tester, CameraProblemKind.permission, permanent: true);

      expect(find.text('Open Settings'), findsOneWidget);
      expect(find.text('Allow camera'), findsNothing);
      expect(find.text('Enter batch manually'), findsOneWidget);

      await tester.tap(find.text('Open Settings'));
      expect(primary, 1);
    });
  });

  testWidgets('no camera offers manual entry and Back', (tester) async {
    await pumpView(tester, CameraProblemKind.noCamera);

    expect(find.text('No camera found'), findsOneWidget);
    expect(
      find.text(
        'This device has no usable camera. You can still enter batch '
        'numbers manually and browse your scan history.',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.no_photography_outlined), findsOneWidget);
    expect(find.text('Enter batch manually'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(find.text('Allow camera'), findsNothing);

    await tester.tap(find.text('Enter batch manually'));
    await tester.tap(find.text('Back'));
    expect(manual, 1);
    expect(back, 1);
    expect(primary, 0);
  });

  testWidgets('error offers Try again and Back, with a generic message', (
    tester,
  ) async {
    await pumpView(tester, CameraProblemKind.error);

    expect(find.text('Camera problem'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);

    await tester.tap(find.text('Try again'));
    await tester.tap(find.text('Back'));
    expect(primary, 1);
    expect(back, 1);
  });

  testWidgets('the back arrow is always available', (tester) async {
    for (final kind in CameraProblemKind.values) {
      back = 0;
      await pumpView(tester, kind);
      await tester.tap(find.byTooltip('Back').first);
      expect(back, 1, reason: '$kind');
    }
  });

  group('no overflow at text scale 1.3 on a 5 inch phone', () {
    for (final kind in CameraProblemKind.values) {
      testWidgets('$kind', (tester) async {
        await pumpView(
          tester,
          kind,
          permanent: true,
          textScale: 1.3,
          size: const Size(360, 640),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
