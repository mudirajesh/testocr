import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/accuracy/accuracy_report.dart';
import 'package:gs1scan/accuracy/accuracy_session.dart';
import 'package:gs1scan/accuracy/accuracy_test_screen.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/utils/constants.dart';
import 'package:gs1scan/utils/scan_metrics.dart';

import 'support/fakes.dart';

const _device = DeviceDetails(
  model: 'Test Phone',
  androidVersion: '14 (API 34)',
  appVersion: '1.0.0+1',
  buildMode: 'debug',
);

// GTIN 08901234567890, batch BN2024X981.
const _goodRaw = '01089012345678901726123110BN2024X981';
// The same pack misread: the batch O/0 confusion.
const _misreadRaw = '01089012345678901726123110BN2O24X981';

void main() {
  test('the harness is disabled unless built with ACCURACY_TEST=true', () {
    expect(kAccuracyTestEnabled, isFalse);
  });

  group('attemptFromScan', () {
    ScanRecord record(String? batch) => ScanRecord(
      id: 'x',
      rawBarcode: '0108901234567890\u001D10${batch ?? ''}',
      barcodeFormat: 'DataMatrix',
      batchNumber: batch,
      gtin: '08901234567890',
      scanTimestamp: DateTime(2026),
      confidenceScore: 0.6,
    );
    const metrics = ScanMetrics(
      firstDetectionMs: 100,
      consensusMs: 700,
      averageFrameMs: 90,
    );

    test('an exact match is correct', () {
      final a = attemptFromScan(
        attemptNumber: 2,
        expectedBatch: 'BN2024X981',
        record: record('BN2024X981'),
        status: 'success',
        warnings: const ['w'],
        metrics: metrics,
      );
      expect(a.correct, isTrue);
      expect(a.scanToResultMs, 700);
      expect(a.attemptNumber, 2);
      expect(a.extractedGtin, '08901234567890');
      expect(a.confidence, 0.6);
      expect(a.warnings, ['w']);
      expect(a.rawVisible, contains('<GS>'));
      expect(a.rawVisible, isNot(contains('\u001D')));
    });

    test('O vs 0 is wrong, case differences are wrong, no batch is wrong', () {
      bool correct(String? extracted) => attemptFromScan(
        attemptNumber: 1,
        expectedBatch: 'BN2024X981',
        record: record(extracted),
        status: 'success',
        warnings: const [],
        metrics: null,
      ).correct;

      expect(correct('BN2O24X981'), isFalse);
      expect(correct('bn2024x981'), isFalse);
      expect(correct(null), isFalse);
    });

    test('no metrics gives no time', () {
      final a = attemptFromScan(
        attemptNumber: 1,
        expectedBatch: 'B',
        record: record('B'),
        status: 'success',
        warnings: const [],
        metrics: null,
      );
      expect(a.scanToResultMs, isNull);
    });
  });

  group('AccuracySession', () {
    test('collects samples and summarises them', () {
      final session = AccuracySession();
      var notified = 0;
      session.addListener(() => notified++);

      session.addSample(
        const SampleResult(
          label: 'A',
          tags: ['Carton'],
          expectedBatch: 'B1',
          expectedGtin: null,
          attempts: [
            AttemptRecord(
              attemptNumber: 1,
              extractedBatch: 'B1',
              extractedGtin: null,
              correct: true,
              scanToResultMs: 500,
              confidence: 1,
              status: 'success',
            ),
          ],
        ),
      );
      expect(session.sampleCount, 1);
      expect(session.summary.accuracy, 1.0);
      expect(notified, 1);

      session.clear();
      expect(session.sampleCount, 0);
      expect(session.summary.isEmpty, isTrue);
    });
  });

  group('AccuracyTestScreen', () {
    late FakeBarcodeSource source;
    late Directory tempDir;
    late List<File> shared;

    setUp(() {
      source = FakeBarcodeSource();
      shared = [];
    });

    Future<void> pumpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      tempDir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('gs1_accuracy'),
      ))!;
      addTearDown(
        () => tester.runAsync(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AccuracyTestScreen(
            source: source,
            database: FakeDb(),
            tempDir: () async => tempDir,
            share: (files) async => shared.addAll(files),
            deviceDetails: () async => _device,
          ),
        ),
      );
    }

    Future<void> setUpSample(
      WidgetTester tester, {
      String label = 'Paracetamol blister 3',
      String batch = 'BN2024X981',
      int attempts = 3,
    }) async {
      await tester.enterText(find.byType(TextField).at(0), label);
      await tester.enterText(find.byType(TextField).at(1), batch);
      await tester.tap(find.text('Blister'));
      await tester.pump();
      for (var i = 10; i > attempts; i--) {
        await tester.tap(find.byTooltip('Fewer attempts'));
      }
      await tester.pump();
      await tester.ensureVisible(find.text('Start scanning'));
      await tester.pump();
      await tester.tap(find.text('Start scanning'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> detect(
      WidgetTester tester,
      String raw, {
      int times = 3,
    }) async {
      for (var i = 0; i < times; i++) {
        source.emit(raw);
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('the setup form needs the expected batch', (tester) async {
      await pumpScreen(tester);

      expect(find.text('Sample 1'), findsOneWidget);
      expect(find.text('Conditions'), findsOneWidget);
      for (final tag in kAccuracyConditionTags) {
        expect(find.text(tag), findsOneWidget);
      }
      expect(find.text('10'), findsOneWidget); // default attempts

      await tester.ensureVisible(find.text('Start scanning'));
      await tester.tap(find.text('Start scanning'));
      await tester.pump();
      expect(
        find.text('Type the batch number printed on the pack'),
        findsOneWidget,
      );
      expect(source.startCalls, 0);
    });

    testWidgets('scans a sample, records attempts and shows the results', (
      tester,
    ) async {
      await pumpScreen(tester);
      await setUpSample(tester);

      // The real pipeline is running on the fake camera.
      expect(source.startCalls, 1);
      expect(find.textContaining('Attempt 1 of 3'), findsOneWidget);
      expect(find.text('Expected: BN2024X981'), findsOneWidget);

      // Attempt 1: read correctly.
      await detect(tester, _goodRaw);
      expect(find.text('Correct'), findsOneWidget);
      expect(find.text('Next attempt'), findsOneWidget);

      // Attempt 2: the O/0 misread.
      await tester.tap(find.text('Next attempt'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('Attempt 2 of 3'), findsOneWidget);
      await detect(tester, _misreadRaw);
      expect(find.text('Wrong'), findsOneWidget);
      expect(find.text('Expected'), findsOneWidget);
      expect(find.text('Got'), findsOneWidget);

      // Attempt 3: skipped.
      await tester.tap(find.text('Next attempt'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Skip / could not scan'));
      await tester.pump();
      expect(find.text('Not scanned'), findsOneWidget);
      expect(find.text('See sample result'), findsOneWidget);

      await tester.tap(find.text('See sample result'));
      await tester.pump(const Duration(milliseconds: 100));

      // Sample summary.
      expect(find.text('Sample result'), findsOneWidget);
      expect(find.text('Correct 1 of 3'), findsOneWidget);
      expect(find.text('33.3%'), findsWidgets);
      expect(find.text('Wrong extractions'), findsOneWidget);
      expect(find.text('Attempt 2'), findsOneWidget);
      expect(find.text('Attempt 3: not scanned'), findsOneWidget);
      expect(find.text('Blister'), findsOneWidget);
      // The camera was released between samples.
      expect(source.disposeCalls, greaterThan(0));
    });

    testWidgets('a session ends with a verdict and a shareable report', (
      tester,
    ) async {
      await pumpScreen(tester);
      await setUpSample(tester, attempts: 1);
      await detect(tester, _goodRaw);
      await tester.tap(find.text('See sample result'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Correct 1 of 1'), findsOneWidget);

      await tester.ensureVisible(find.text('Finish session'));
      await tester.tap(find.text('Finish session'));
      await tester.pump();

      expect(find.text('Session summary'), findsOneWidget);
      expect(find.textContaining('1 of 1 correct'), findsOneWidget);
      expect(find.text('100.0%'), findsWidgets);
      expect(find.text('By condition'), findsOneWidget);

      await tester.ensureVisible(find.text('Share report'));
      await tester.tap(find.text('Share report'));
      await tester.pump();
      expect(find.text('Preparing report...'), findsOneWidget);
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(shared.length, 2);
      final names = shared.map((f) => f.path.split('/').last).toList();
      expect(
        names.any(
          (n) => RegExp(r'^accuracy_report_\d{8}_\d{6}\.csv$').hasMatch(n),
        ),
        isTrue,
      );
      expect(
        names.any(
          (n) => RegExp(r'^accuracy_report_\d{8}_\d{6}\.md$').hasMatch(n),
        ),
        isTrue,
      );

      final csv = shared.firstWhere((f) => f.path.endsWith('.csv'));
      final bytes = (await tester.runAsync(csv.readAsBytes))!;
      expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      final text = String.fromCharCodes(bytes.sublist(3));
      expect(text, startsWith('sample,attempt,tags'));
      expect(text, contains('Paracetamol blister 3'));
      expect(text, contains('Test Phone'));

      final md = shared.firstWhere((f) => f.path.endsWith('.md'));
      final mdText = (await tester.runAsync(md.readAsString))!;
      expect(mdText, contains('GS1 Scan accuracy test'));
      expect(mdText, contains('Test Phone (Android 14 (API 34))'));
    });

    testWidgets('Next sample returns to the form with a new number', (
      tester,
    ) async {
      await pumpScreen(tester);
      await setUpSample(tester, attempts: 1);
      await detect(tester, _goodRaw);
      await tester.tap(find.text('See sample result'));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.ensureVisible(find.text('Next sample'));
      await tester.tap(find.text('Next sample'));
      await tester.pump();

      expect(find.text('Sample 2'), findsOneWidget);
      expect(find.text('Finish session (1 sample)'), findsOneWidget);
    });

    testWidgets('an empty session cannot be shared', (tester) async {
      await pumpScreen(tester);
      // Reach the summary without any attempts: set up a sample, end it.
      await setUpSample(tester, attempts: 1);
      await tester.tap(find.byTooltip('End this sample'));
      await tester.pump();
      await tester.tap(find.text('End sample'));
      await tester.pump(const Duration(milliseconds: 200));

      // Back on the setup form, with no samples to finish.
      expect(find.text('Sample 1'), findsOneWidget);
      expect(find.textContaining('Finish session'), findsNothing);
    });

    testWidgets('no overflow at text scale 1.3 on a 5 inch phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: AccuracyTestScreen(
            source: source,
            database: FakeDb(),
            share: (files) async {},
            deviceDetails: () async => _device,
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      await tester.enterText(find.byType(TextField).at(1), 'BN2024X981');
      await tester.ensureVisible(find.text('Start scanning'));
      await tester.tap(find.text('Start scanning'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 0; i < 3; i++) {
        source.emit(_misreadRaw);
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Wrong'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
