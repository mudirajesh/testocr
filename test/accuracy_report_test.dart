import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/accuracy/accuracy_report.dart';

AttemptRecord attempt(
  int n, {
  String? extracted = 'BN1',
  bool correct = true,
  int? ms = 800,
  double? confidence = 0.6,
  String status = 'success',
  String raw = '',
  List<String> warnings = const [],
  String? gtin = '08901234567890',
}) => AttemptRecord(
  attemptNumber: n,
  extractedBatch: extracted,
  extractedGtin: gtin,
  correct: correct,
  scanToResultMs: ms,
  confidence: confidence,
  status: status,
  rawVisible: raw,
  warnings: warnings,
);

SampleResult sample(
  String label,
  List<AttemptRecord> attempts, {
  List<String> tags = const ['Carton'],
  String expected = 'BN1',
}) => SampleResult(
  label: label,
  tags: tags,
  expectedBatch: expected,
  expectedGtin: '08901234567890',
  attempts: attempts,
);

/// [correct] right attempts followed by wrong ones, [total] in all.
List<AttemptRecord> attemptsWith(int correct, int total, {int ms = 800}) => [
  for (var i = 0; i < total; i++)
    attempt(
      i + 1,
      extracted: i < correct ? 'BN1' : 'BN7',
      correct: i < correct,
      ms: ms,
    ),
];

const device = DeviceDetails(
  model: 'Redmi Note 11S',
  androidVersion: '13',
  appVersion: '1.0.0+1',
  buildMode: 'profile',
);

void main() {
  group('exact batch match', () {
    test('is case-sensitive and does not normalise', () {
      expect(isExactBatchMatch('BN2024X981', 'BN2024X981'), isTrue);
      expect(isExactBatchMatch('BN2024X981', 'bn2024x981'), isFalse);
      expect(isExactBatchMatch('BN2024X981', 'BN2O24X981'), isFalse);
      expect(isExactBatchMatch('BN2024X981', 'BN2024X981 '), isFalse);
      expect(isExactBatchMatch('BN2024X981', null), isFalse);
    });
  });

  group('median and 95th percentile', () {
    test('odd count', () {
      expect(medianOf([30, 10, 20]), 20);
      expect(medianOf([5]), 5);
    });

    test('even count averages the middle pair', () {
      expect(medianOf([10, 20, 30, 40]), 25);
      expect(medianOf([1, 2]), 1.5);
    });

    test('empty is null', () {
      expect(medianOf([]), isNull);
      expect(percentileOf([], 95), isNull);
    });

    test('p95 uses nearest rank', () {
      final twenty = [for (var i = 1; i <= 20; i++) i * 100]; // 100..2000
      expect(percentileOf(twenty, 95), 1900); // rank ceil(19) = 19
      final hundred = [for (var i = 1; i <= 100; i++) i];
      expect(percentileOf(hundred, 95), 95);
      expect(percentileOf([42], 95), 42);
      expect(percentileOf([10, 20, 30], 95), 30);
    });

    test('p95 ignores input order', () {
      expect(percentileOf([500, 100, 400, 200, 300], 95), 500);
    });
  });

  group('sample accuracy', () {
    test('counts correct over all attempts', () {
      final s = sample('A', attemptsWith(8, 10));
      expect(s.total, 10);
      expect(s.correctCount, 8);
      expect(s.accuracy, 0.8);
      expect(s.belowThreshold, isTrue);
      expect(s.wrongAttempts.length, 2);
    });

    test('exactly 98% is not below the threshold', () {
      expect(sample('A', attemptsWith(49, 50)).belowThreshold, isFalse);
      expect(sample('A', attemptsWith(48, 50)).belowThreshold, isTrue);
      expect(sample('A', attemptsWith(10, 10)).belowThreshold, isFalse);
      expect(sample('A', attemptsWith(9, 10)).belowThreshold, isTrue);
    });

    test('a skipped attempt is wrong and has no time', () {
      final s = sample('A', [
        attempt(1),
        const AttemptRecord.failed(attemptNumber: 2),
      ]);
      expect(s.correctCount, 1);
      expect(s.times, [800]);
      expect(s.wrongAttempts.single.skipped, isTrue);
      expect(s.wrongAttempts.single.status, 'skipped');
    });

    test('an empty sample has no accuracy', () {
      final s = sample('A', []);
      expect(s.accuracy, isNull);
      expect(s.belowThreshold, isFalse);
      expect(s.medianMs, isNull);
    });

    test('times: median and p95 of the timed attempts', () {
      final s = sample('A', [
        attempt(1, ms: 1000),
        attempt(2, ms: 2000),
        attempt(3, ms: 3000),
        attempt(4, ms: 4000),
      ]);
      expect(s.medianMs, 2500);
      expect(s.p95Ms, 4000);
    });
  });

  group('session summary', () {
    test('overall accuracy is correct / total attempts', () {
      final summary = SessionSummary.from([
        sample('A', attemptsWith(10, 10)),
        sample('B', attemptsWith(8, 10)),
      ]);
      expect(summary.totalAttempts, 20);
      expect(summary.correctAttempts, 18);
      expect(summary.accuracy, 0.9);
      expect(summary.samplesBelowThreshold, 1);
    });

    test('per-condition breakdown counts each tag of a sample', () {
      final summary = SessionSummary.from([
        sample('A', attemptsWith(10, 10), tags: ['Carton']),
        sample('B', attemptsWith(5, 10), tags: ['Blister', 'Worn']),
        sample('C', attemptsWith(9, 10), tags: ['Blister']),
      ]);

      TagStats tag(String name) =>
          summary.tagStats.singleWhere((t) => t.tag == name);
      expect(tag('Carton').correct, 10);
      expect(tag('Carton').total, 10);
      expect(tag('Blister').correct, 14);
      expect(tag('Blister').total, 20);
      expect(tag('Blister').accuracy, 0.7);
      expect(tag('Worn').accuracy, 0.5);
      expect(summary.tagStats.any((t) => t.tag == 'Bottle'), isFalse);
    });

    test('tags come out in the standard order', () {
      final summary = SessionSummary.from([
        sample('A', attemptsWith(1, 1), tags: ['Worn', 'Carton', 'Custom']),
      ]);
      expect(summary.tagStats.map((t) => t.tag), ['Carton', 'Worn', 'Custom']);
    });

    test('time statistics and attempts over the target', () {
      final summary = SessionSummary.from([
        sample('A', [
          attempt(1, ms: 500),
          attempt(2, ms: 2000), // exactly the target: not over
          attempt(3, ms: 2001),
          attempt(4, ms: 3500),
          const AttemptRecord.failed(attemptNumber: 5),
        ]),
      ]);
      expect(summary.attemptsOverTarget, 2);
      expect(summary.medianMs, (2000 + 2001) / 2);
      expect(summary.p95Ms, 3500);
    });

    test('an empty session', () {
      final summary = SessionSummary.from([]);
      expect(summary.isEmpty, isTrue);
      expect(summary.accuracy, isNull);
      expect(summary.medianMs, isNull);
      expect(summary.p95Ms, isNull);
      expect(summary.tagStats, isEmpty);
      expect(summary.accuracyVerdict, Verdict.noData);
      expect(summary.timeVerdict, Verdict.noData);
      expect(summary.overallVerdict, Verdict.noData);
      expect(summary.samplesBelowThreshold, 0);

      final sampleWithoutAttempts = SessionSummary.from([sample('A', [])]);
      expect(sampleWithoutAttempts.overallVerdict, Verdict.noData);
    });
  });

  group('PASS / FAIL', () {
    test('accuracy passes at exactly 98% and fails just below', () {
      final pass = SessionSummary.from([sample('A', attemptsWith(49, 50))]);
      expect(pass.accuracy, 0.98);
      expect(pass.accuracyVerdict, Verdict.pass);

      final fail = SessionSummary.from([sample('A', attemptsWith(48, 50))]);
      expect(fail.accuracyVerdict, Verdict.fail);

      expect(
        SessionSummary.from([sample('A', attemptsWith(98, 100))])
            .accuracyVerdict,
        Verdict.pass,
      );
      expect(
        SessionSummary.from([sample('A', attemptsWith(97, 100))])
            .accuracyVerdict,
        Verdict.fail,
      );
    });

    test('the time target is judged on the 95th percentile', () {
      // p95 of 20 values is the 19th: 2000 passes, 2001 fails.
      List<AttemptRecord> twentyWith(int slow) => [
        for (var i = 1; i <= 19; i++) attempt(i, ms: 1000),
        attempt(20, ms: 5000), // one outlier is outside the 95th percentile
      ].map((a) => a).toList()..[18] = attempt(19, ms: slow);

      final within = SessionSummary.from([sample('A', twentyWith(2000))]);
      expect(within.p95Ms, 2000);
      expect(within.timeVerdict, Verdict.pass);

      final over = SessionSummary.from([sample('A', twentyWith(2001))]);
      expect(over.timeVerdict, Verdict.fail);
    });

    test('overall needs both accuracy and speed', () {
      final good = SessionSummary.from([sample('A', attemptsWith(10, 10))]);
      expect(good.overallVerdict, Verdict.pass);

      final slow = SessionSummary.from([
        sample('A', attemptsWith(10, 10, ms: 3000)),
      ]);
      expect(slow.accuracyVerdict, Verdict.pass);
      expect(slow.timeVerdict, Verdict.fail);
      expect(slow.overallVerdict, Verdict.fail);

      final inaccurate = SessionSummary.from([
        sample('A', attemptsWith(5, 10)),
      ]);
      expect(inaccurate.overallVerdict, Verdict.fail);
    });

    test('accuracy alone decides when no scan has a time', () {
      final skipped = SessionSummary.from([
        sample('A', [
          for (var i = 1; i <= 10; i++) AttemptRecord.failed(attemptNumber: i),
        ]),
      ]);
      expect(skipped.timeVerdict, Verdict.noData);
      expect(skipped.accuracyVerdict, Verdict.fail);
      expect(skipped.overallVerdict, Verdict.fail);
    });

    test('verdict labels', () {
      expect(verdictLabel(Verdict.pass), 'PASS');
      expect(verdictLabel(Verdict.fail), 'FAIL');
      expect(verdictLabel(Verdict.noData), 'NO DATA');
    });
  });

  group('character diff', () {
    String marked(List<DiffChar> chars) =>
        chars.map((c) => c.differs ? '[${c.char}]' : c.char).join();

    test('identical strings have no differences', () {
      final d = diffCharacters('BN2024X981', 'BN2024X981');
      expect(d.identical, isTrue);
      expect(marked(d.expected), 'BN2024X981');
    });

    test('an O/0 swap highlights just that character on both sides', () {
      final d = diffCharacters('BN2024X981', 'BN2O24X981');
      expect(marked(d.expected), 'BN2[0]24X981');
      expect(marked(d.actual), 'BN2[O]24X981');
      expect(d.identical, isFalse);
    });

    test('a dropped character does not flag the rest', () {
      final d = diffCharacters('BN2024X981', 'BN204X981');
      // Exactly one expected character is missing from the actual string, and
      // everything after it still lines up.
      expect(d.expected.where((c) => c.differs).length, 1);
      expect(d.actual.any((c) => c.differs), isFalse);
      expect(marked(d.actual), 'BN204X981');
      expect(d.expected.map((c) => c.char).join(), 'BN2024X981');
      expect(d.expected.last.differs, isFalse);
    });

    test('an extra character is flagged only in the actual string', () {
      final d = diffCharacters('BN204', 'BN2024');
      expect(marked(d.expected), 'BN204');
      expect(
        marked(d.actual).replaceAll('[', '').replaceAll(']', ''),
        'BN2024',
      );
      expect(d.actual.where((c) => c.differs).length, 1);
    });

    test('completely different strings flag everything', () {
      final d = diffCharacters('ABC', 'XYZ');
      expect(marked(d.expected), '[A][B][C]');
      expect(marked(d.actual), '[X][Y][Z]');
    });

    test('empty cases', () {
      expect(marked(diffCharacters('', 'AB').actual), '[A][B]');
      expect(marked(diffCharacters('AB', '').expected), '[A][B]');
      expect(diffCharacters('', '').identical, isTrue);
    });

    test('case differences are differences', () {
      expect(diffCharacters('Ab', 'AB').identical, isFalse);
    });
  });

  group('CSV export', () {
    List<List<dynamic>> parse(String text) => Csv().decode(text);

    test('has the expected columns', () {
      final rows = parse(buildAccuracyCsv([], device));
      expect(rows.single, kAccuracyCsvHeaders);
      expect(
        kAccuracyCsvHeaders,
        containsAll([
          'sample',
          'tags',
          'expected_batch',
          'extracted_batch',
          'correct',
          'scan_ms',
          'confidence',
          'status',
          'device_model',
          'app_version',
          'build_mode',
        ]),
      );
    });

    test('one row per attempt with the right values', () {
      final csv = buildAccuracyCsv([
        sample(
          'Paracetamol blister 3',
          [
            attempt(1, ms: 640, confidence: 0.6, raw: '01...<GS>10BN1'),
            attempt(
              2,
              extracted: 'BN7',
              correct: false,
              ms: 1500,
              status: 'needsReview',
              warnings: ['w1', 'w2'],
            ),
            const AttemptRecord.failed(attemptNumber: 3),
          ],
          tags: ['Blister', 'Worn'],
        ),
      ], device);

      final rows = parse(csv);
      expect(rows.length, 4);
      Map<String, dynamic> row(int i) => {
        for (var c = 0; c < kAccuracyCsvHeaders.length; c++)
          kAccuracyCsvHeaders[c]: rows[i][c],
      };

      expect(row(1)['sample'], 'Paracetamol blister 3');
      expect(row(1)['attempt'].toString(), '1');
      expect(row(1)['tags'], 'Blister; Worn');
      expect(row(1)['expected_batch'], 'BN1');
      expect(row(1)['extracted_batch'], 'BN1');
      expect(row(1)['correct'], 'yes');
      expect(row(1)['scan_ms'].toString(), '640');
      expect(row(1)['confidence'].toString(), '0.60');
      expect(row(1)['status'], 'success');
      expect(row(1)['raw'], '01...<GS>10BN1');
      expect(row(1)['device_model'], 'Redmi Note 11S');
      expect(row(1)['android_version'].toString(), '13');
      expect(row(1)['app_version'], '1.0.0+1');
      expect(row(1)['build_mode'], 'profile');

      expect(row(2)['correct'], 'no');
      expect(row(2)['extracted_batch'], 'BN7');
      expect(row(2)['status'], 'needsReview');
      expect(row(2)['warnings'], 'w1 | w2');

      expect(row(3)['correct'], 'no');
      expect(row(3)['extracted_batch'], '');
      expect(row(3)['scan_ms'], '');
      expect(row(3)['status'], 'skipped');
    });

    test('GTIN keeps its leading zero and risky text is neutralised', () {
      final rows = parse(
        buildAccuracyCsv([
          sample('=cmd()', [attempt(1, extracted: '@x')]),
        ], device),
      );
      expect(rows[1][0], "'=cmd()");
      expect(rows[1][4], "'@x");
      expect(rows[1][9], '="08901234567890"');
    });

    test('commas and quotes in values round-trip', () {
      final rows = parse(
        buildAccuracyCsv([
          sample('Box, "large"', [attempt(1)]),
        ], device),
      );
      expect(rows[1][0], 'Box, "large"');
    });
  });

  group('markdown summary', () {
    test('states the verdict, device and numbers', () {
      final summary = SessionSummary.from([
        sample('Pack A', attemptsWith(10, 10), tags: ['Carton']),
        sample('Pack B', attemptsWith(9, 10), tags: ['Blister']),
      ]);
      final md = buildAccuracyMarkdown(summary, device, DateTime(2026, 10, 6));

      expect(md, contains('## Result: FAIL'));
      expect(md, contains('Redmi Note 11S (Android 13)'));
      expect(md, contains('1.0.0+1 (profile build)'));
      expect(md, contains('19 / 20 = 95.0%'));
      expect(md, contains('| Blister | 9 | 10 | 90.0% |'));
      expect(md, contains('## Wrong extractions'));
      expect(md, contains('| Pack B | 10 | BN1 | BN7 |'));
    });

    test('an all-correct session shows PASS and no wrong table', () {
      final summary = SessionSummary.from([
        sample('Pack A', attemptsWith(10, 10)),
      ]);
      final md = buildAccuracyMarkdown(summary, device, DateTime(2026, 10, 6));
      expect(md, contains('## Result: PASS'));
      expect(md, isNot(contains('## Wrong extractions')));
    });

    test('an empty session does not throw', () {
      final md = buildAccuracyMarkdown(
        SessionSummary.from([]),
        device,
        DateTime(2026, 10, 6),
      );
      expect(md, contains('## Result: NO DATA'));
      expect(md, contains('n/a'));
    });

    test('pipes in user text do not break the table', () {
      final summary = SessionSummary.from([
        sample('A|B', attemptsWith(10, 10)),
      ]);
      final md = buildAccuracyMarkdown(summary, device, DateTime(2026, 10, 6));
      expect(md, contains(r'A\|B'));
    });
  });
}
