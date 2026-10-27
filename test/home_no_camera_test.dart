import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/providers/history_provider.dart';
import 'package:gs1scan/screens/home_screen.dart';
import 'package:gs1scan/services/camera_availability.dart';
import 'package:gs1scan/services/database_service.dart';
import 'package:provider/provider.dart';

import 'support/spy_db.dart';

class _FakeAvailability implements CameraAvailability {
  _FakeAvailability(this.answer);

  final Completer<bool> answer;

  @override
  Future<bool> hasCamera() => answer.future;
}

void main() {
  late SpyDb db;
  late HistoryProvider history;

  setUp(() {
    db = SpyDb();
    history = HistoryProvider(db);
  });

  Future<CameraAvailabilityProvider> pumpHome(
    WidgetTester tester, {
    bool? hasCamera,
  }) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(history.dispose);
    addTearDown(() => tester.runAsync(db.close));

    await tester.runAsync(history.loadInitial);

    final answer = Completer<bool>();
    final availability = CameraAvailabilityProvider(_FakeAvailability(answer));
    addTearDown(availability.dispose);
    unawaited(availability.check());
    if (hasCamera != null) answer.complete(hasCamera);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<DatabaseService>.value(value: db),
          ChangeNotifierProvider<HistoryProvider>.value(value: history),
          ChangeNotifierProvider<CameraAvailabilityProvider>.value(
            value: availability,
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    return availability;
  }

  const bannerText =
      'No camera found. Scanning is disabled, but you can enter batch '
      'numbers manually and browse your history.';

  double scanCardOpacity(WidgetTester tester) {
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.text('Scan Barcode'),
            matching: find.byType(Opacity),
          )
          .first,
    );
    return opacity.opacity;
  }

  testWidgets('without a camera: banner and a dimmed Scan card', (
    tester,
  ) async {
    await pumpHome(tester, hasCamera: false);

    expect(find.text(bannerText), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.text('Enter manually'), findsOneWidget);
    expect(scanCardOpacity(tester), 0.5);
  });

  testWidgets('tapping the dimmed Scan card only shows a message', (
    tester,
  ) async {
    await pumpHome(tester, hasCamera: false);

    await tester.tap(find.text('Scan Barcode'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text("Scanning isn't available on this device"),
      findsOneWidget,
    );
    expect(find.text('Starting camera...'), findsNothing);
    expect(find.text('Home'), findsNothing);
  });

  testWidgets('History still opens', (tester) async {
    await pumpHome(tester, hasCamera: false);

    await tester.tap(find.text('Scan History'));
    await tester.pump();
    // The empty History shows a repeating animation, so no pumpAndSettle.
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Scan Log Details'), findsOneWidget);
  });

  testWidgets('Enter manually opens Manual Entry', (tester) async {
    await pumpHome(tester, hasCamera: false);

    await tester.ensureVisible(find.text('Enter manually'));
    await tester.tap(find.text('Enter manually'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.text('Manual Entry'), findsOneWidget);
    expect(find.text('Save Entry'), findsOneWidget);
  });

  testWidgets('with a camera: no banner and a normal Scan card', (
    tester,
  ) async {
    await pumpHome(tester, hasCamera: true);

    expect(find.text(bannerText), findsNothing);
    expect(find.text('Enter manually'), findsNothing);
    expect(scanCardOpacity(tester), 1.0);
  });

  testWidgets('while the check is still running nothing is shown', (
    tester,
  ) async {
    await pumpHome(tester); // never answers

    expect(find.text(bannerText), findsNothing);
    expect(scanCardOpacity(tester), 1.0);
    expect(find.text('Scan Barcode'), findsOneWidget);
  });

  testWidgets('no overflow at text scale 1.3 on a 5 inch phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(history.dispose);
    addTearDown(() => tester.runAsync(db.close));
    await tester.runAsync(history.loadInitial);

    final answer = Completer<bool>()..complete(false);
    final availability = CameraAvailabilityProvider(_FakeAvailability(answer));
    addTearDown(availability.dispose);
    await tester.runAsync(availability.check);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<DatabaseService>.value(value: db),
          ChangeNotifierProvider<HistoryProvider>.value(value: history),
          ChangeNotifierProvider<CameraAvailabilityProvider>.value(
            value: availability,
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text(bannerText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
