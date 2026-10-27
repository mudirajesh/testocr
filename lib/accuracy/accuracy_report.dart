// Accuracy-test maths and report builders. Pure Dart: no Flutter imports, so
// everything here is unit-tested without a device.

import 'dart:math' as math;

import 'package:csv/csv.dart';

import '../utils/csv_text.dart';

/// Acceptance threshold for batch-number accuracy, in percent.
const kAccuracyThresholdPercent = 98;

/// Scan-to-result target. The time verdict uses the 95th percentile, so one
/// slow outlier in twenty does not fail the run but a slow typical scan does.
const kScanTimeTargetMs = 2000;

/// Condition tags a tester can put on a sample.
const kAccuracyConditionTags = [
  'Carton',
  'Blister',
  'Bottle',
  'Worn',
  'Low contrast',
  'Curved',
  'Low light',
];

/// Exact match: case-sensitive, nothing normalised. A missing extraction is
/// never correct.
bool isExactBatchMatch(String expected, String? extracted) =>
    extracted != null && extracted == expected;

/// Median of [values] (the mean of the two middle values for an even count);
/// null when empty.
double? medianOf(List<int> values) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid].toDouble()
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Nearest-rank percentile (e.g. [percent] 95): the smallest value such that
/// at least that share of values is at or below it. Null when empty.
int? percentileOf(List<int> values, int percent) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  final rank = (percent / 100 * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

/// One scan attempt on one sample.
class AttemptRecord {
  const AttemptRecord({
    required this.attemptNumber,
    required this.extractedBatch,
    required this.extractedGtin,
    required this.correct,
    required this.scanToResultMs,
    required this.confidence,
    required this.status,
    this.warnings = const [],
    this.rawVisible = '',
    this.skipped = false,
  });

  /// A "could not scan / skipped" attempt: always counted as wrong.
  const AttemptRecord.failed({required this.attemptNumber})
    : extractedBatch = null,
      extractedGtin = null,
      correct = false,
      scanToResultMs = null,
      confidence = null,
      status = 'skipped',
      warnings = const [],
      rawVisible = '',
      skipped = true;

  final int attemptNumber;
  final String? extractedBatch;
  final String? extractedGtin;
  final bool correct;

  /// First detection to acceptance; null when nothing was accepted.
  final int? scanToResultMs;
  final double? confidence;

  /// success, needsReview, lowConfidence or skipped.
  final String status;
  final List<String> warnings;

  /// Raw string with the GS character shown as `<GS>`.
  final String rawVisible;
  final bool skipped;
}

/// All attempts for one physical sample (pack).
class SampleResult {
  const SampleResult({
    required this.label,
    required this.tags,
    required this.expectedBatch,
    required this.expectedGtin,
    required this.attempts,
  });

  final String label;
  final List<String> tags;
  final String expectedBatch;
  final String? expectedGtin;
  final List<AttemptRecord> attempts;

  int get total => attempts.length;
  int get correctCount => attempts.where((a) => a.correct).length;

  /// 0..1, null without attempts.
  double? get accuracy => total == 0 ? null : correctCount / total;

  /// Below the acceptance threshold (integer maths, so exactly 98% passes).
  bool get belowThreshold =>
      total > 0 && correctCount * 100 < total * kAccuracyThresholdPercent;

  List<int> get times => [
    for (final a in attempts)
      if (a.scanToResultMs != null) a.scanToResultMs!,
  ];

  double? get medianMs => medianOf(times);
  int? get p95Ms => percentileOf(times, 95);

  /// Attempts that produced a wrong (or no) extraction.
  List<AttemptRecord> get wrongAttempts => [
    for (final a in attempts)
      if (!a.correct) a,
  ];
}

class TagStats {
  const TagStats({
    required this.tag,
    required this.correct,
    required this.total,
  });

  final String tag;
  final int correct;
  final int total;

  double? get accuracy => total == 0 ? null : correct / total;
}

enum Verdict { pass, fail, noData }

/// Roll-up of a whole test session.
class SessionSummary {
  SessionSummary._({
    required this.samples,
    required this.totalAttempts,
    required this.correctAttempts,
    required this.tagStats,
    required this.medianMs,
    required this.p95Ms,
    required this.attemptsOverTarget,
    required this.samplesBelowThreshold,
  });

  factory SessionSummary.from(List<SampleResult> samples) {
    final attempts = [for (final s in samples) ...s.attempts];
    final times = [
      for (final a in attempts)
        if (a.scanToResultMs != null) a.scanToResultMs!,
    ];

    // An attempt counts once for every tag of its sample.
    final tagTotals = <String, int>{};
    final tagCorrect = <String, int>{};
    for (final sample in samples) {
      for (final tag in sample.tags) {
        tagTotals[tag] = (tagTotals[tag] ?? 0) + sample.total;
        tagCorrect[tag] = (tagCorrect[tag] ?? 0) + sample.correctCount;
      }
    }
    final orderedTags = [
      ...kAccuracyConditionTags.where(tagTotals.containsKey),
      ...tagTotals.keys.where((t) => !kAccuracyConditionTags.contains(t)),
    ];

    return SessionSummary._(
      samples: samples,
      totalAttempts: attempts.length,
      correctAttempts: attempts.where((a) => a.correct).length,
      tagStats: [
        for (final tag in orderedTags)
          TagStats(
            tag: tag,
            correct: tagCorrect[tag] ?? 0,
            total: tagTotals[tag] ?? 0,
          ),
      ],
      medianMs: medianOf(times),
      p95Ms: percentileOf(times, 95),
      attemptsOverTarget: times.where((t) => t > kScanTimeTargetMs).length,
      samplesBelowThreshold: samples.where((s) => s.belowThreshold).length,
    );
  }

  final List<SampleResult> samples;
  final int totalAttempts;
  final int correctAttempts;
  final List<TagStats> tagStats;
  final double? medianMs;
  final int? p95Ms;

  /// Attempts slower than [kScanTimeTargetMs].
  final int attemptsOverTarget;
  final int samplesBelowThreshold;

  bool get isEmpty => totalAttempts == 0;

  /// 0..1, null for an empty session.
  double? get accuracy =>
      totalAttempts == 0 ? null : correctAttempts / totalAttempts;

  /// Accuracy verdict: 98% or higher passes (exactly 98% passes).
  Verdict get accuracyVerdict {
    if (totalAttempts == 0) return Verdict.noData;
    return correctAttempts * 100 >= totalAttempts * kAccuracyThresholdPercent
        ? Verdict.pass
        : Verdict.fail;
  }

  /// Speed verdict: the 95th-percentile scan time must be within the target.
  Verdict get timeVerdict {
    final p95 = p95Ms;
    if (p95 == null) return Verdict.noData;
    return p95 <= kScanTimeTargetMs ? Verdict.pass : Verdict.fail;
  }

  /// Overall: both must pass; any failure fails; no attempts is no data.
  Verdict get overallVerdict {
    if (isEmpty) return Verdict.noData;
    if (accuracyVerdict == Verdict.fail || timeVerdict == Verdict.fail) {
      return Verdict.fail;
    }
    if (accuracyVerdict == Verdict.pass && timeVerdict != Verdict.fail) {
      return Verdict.pass;
    }
    return Verdict.noData;
  }
}

// ---------------------------------------------------------------------------
// Character diff

class DiffChar {
  const DiffChar(this.char, {required this.differs});

  final String char;
  final bool differs;
}

class CharDiff {
  const CharDiff({required this.expected, required this.actual});

  /// The expected string, differing characters flagged.
  final List<DiffChar> expected;

  /// The extracted string, differing characters flagged.
  final List<DiffChar> actual;

  bool get identical =>
      !expected.any((c) => c.differs) && !actual.any((c) => c.differs);
}

/// Marks the characters that differ between [expected] and [actual], using a
/// longest-common-subsequence alignment so one inserted or dropped character
/// does not flag everything after it.
CharDiff diffCharacters(String expected, String actual) {
  final a = expected.split('');
  final b = actual.split('');
  final lcs = List.generate(
    a.length + 1,
    (_) => List<int>.filled(b.length + 1, 0),
  );
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }

  final expectedOut = <DiffChar>[];
  final actualOut = <DiffChar>[];
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      expectedOut.add(DiffChar(a[i], differs: false));
      actualOut.add(DiffChar(b[j], differs: false));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      expectedOut.add(DiffChar(a[i++], differs: true));
    } else {
      actualOut.add(DiffChar(b[j++], differs: true));
    }
  }
  while (i < a.length) {
    expectedOut.add(DiffChar(a[i++], differs: true));
  }
  while (j < b.length) {
    actualOut.add(DiffChar(b[j++], differs: true));
  }
  return CharDiff(expected: expectedOut, actual: actualOut);
}

// ---------------------------------------------------------------------------
// Export

/// Where and how the test ran.
class DeviceDetails {
  const DeviceDetails({
    required this.model,
    required this.androidVersion,
    required this.appVersion,
    required this.buildMode,
  });

  final String model;
  final String androidVersion;
  final String appVersion;

  /// debug, profile or release.
  final String buildMode;
}

const kAccuracyCsvHeaders = [
  'sample',
  'attempt',
  'tags',
  'expected_batch',
  'extracted_batch',
  'correct',
  'scan_ms',
  'confidence',
  'status',
  'expected_gtin',
  'extracted_gtin',
  'warnings',
  'raw',
  'device_model',
  'android_version',
  'app_version',
  'build_mode',
];

/// One row per attempt.
String buildAccuracyCsv(List<SampleResult> samples, DeviceDetails device) {
  final rows = <List<Object?>>[List<Object?>.from(kAccuracyCsvHeaders)];
  for (final sample in samples) {
    for (final a in sample.attempts) {
      rows.add([
        csvSafeText(sample.label),
        a.attemptNumber,
        csvSafeText(sample.tags.join('; ')),
        csvSafeText(sample.expectedBatch),
        csvSafeText(a.extractedBatch),
        a.correct ? 'yes' : 'no',
        a.scanToResultMs ?? '',
        a.confidence == null ? '' : a.confidence!.toStringAsFixed(2),
        a.status,
        csvSafeText(sample.expectedGtin, protectDigits: true),
        csvSafeText(a.extractedGtin, protectDigits: true),
        csvSafeText(a.warnings.join(' | ')),
        csvSafeText(a.rawVisible),
        csvSafeText(device.model),
        csvSafeText(device.androidVersion),
        csvSafeText(device.appVersion),
        device.buildMode,
      ]);
    }
  }
  return Csv(lineDelimiter: '\r\n').encode(rows);
}

String _percent(double? value) =>
    value == null ? 'n/a' : '${(value * 100).toStringAsFixed(1)}%';

String _ms(num? value) => value == null
    ? 'n/a'
    : '${value is double ? value.toStringAsFixed(0) : value} ms';

String verdictLabel(Verdict v) => switch (v) {
  Verdict.pass => 'PASS',
  Verdict.fail => 'FAIL',
  Verdict.noData => 'NO DATA',
};

/// A short human-readable summary of the session.
String buildAccuracyMarkdown(
  SessionSummary summary,
  DeviceDetails device,
  DateTime generatedAt,
) {
  final b = StringBuffer()
    ..writeln('# GS1 Scan accuracy test')
    ..writeln()
    ..writeln('- Date: ${generatedAt.toIso8601String()}')
    ..writeln('- Device: ${device.model} (Android ${device.androidVersion})')
    ..writeln('- App version: ${device.appVersion} (${device.buildMode} build)')
    ..writeln()
    ..writeln('## Result: ${verdictLabel(summary.overallVerdict)}')
    ..writeln()
    ..writeln(
      '- Batch accuracy: ${summary.correctAttempts} / ${summary.totalAttempts} '
      '= ${_percent(summary.accuracy)} '
      '(target $kAccuracyThresholdPercent%) - '
      '${verdictLabel(summary.accuracyVerdict)}',
    )
    ..writeln(
      '- Scan time: median ${_ms(summary.medianMs)}, '
      '95th percentile ${_ms(summary.p95Ms)} '
      '(target $kScanTimeTargetMs ms) - '
      '${verdictLabel(summary.timeVerdict)}',
    )
    ..writeln(
      '- Attempts over $kScanTimeTargetMs ms: ${summary.attemptsOverTarget}',
    )
    ..writeln(
      '- Samples below $kAccuracyThresholdPercent%: '
      '${summary.samplesBelowThreshold} of ${summary.samples.length}',
    );

  if (summary.tagStats.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## By condition')
      ..writeln()
      ..writeln('| Condition | Correct | Attempts | Accuracy |')
      ..writeln('|---|---|---|---|');
    for (final t in summary.tagStats) {
      b.writeln(
        '| ${t.tag} | ${t.correct} | ${t.total} | ${_percent(t.accuracy)} |',
      );
    }
  }

  if (summary.samples.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## Samples')
      ..writeln()
      ..writeln(
        '| Sample | Conditions | Expected batch | Correct | Accuracy | Median |',
      )
      ..writeln('|---|---|---|---|---|---|');
    for (final s in summary.samples) {
      b.writeln(
        '| ${_mdCell(s.label)} | ${_mdCell(s.tags.join(', '))} | '
        '${_mdCell(s.expectedBatch)} | ${s.correctCount} / ${s.total} | '
        '${_percent(s.accuracy)} | ${_ms(s.medianMs)} |',
      );
    }

    final wrong = [
      for (final s in summary.samples)
        for (final a in s.wrongAttempts) (s, a),
    ];
    if (wrong.isNotEmpty) {
      b
        ..writeln()
        ..writeln('## Wrong extractions')
        ..writeln()
        ..writeln('| Sample | Attempt | Expected | Extracted |')
        ..writeln('|---|---|---|---|');
      for (final (s, a) in wrong) {
        b.writeln(
          '| ${_mdCell(s.label)} | ${a.attemptNumber} | '
          '${_mdCell(s.expectedBatch)} | '
          '${a.skipped ? '(skipped / not scanned)' : _mdCell(a.extractedBatch ?? '(nothing)')} |',
        );
      }
    }
  }
  return b.toString();
}

/// Keeps user text from breaking a Markdown table cell.
String _mdCell(String value) =>
    value.replaceAll('|', r'\|').replaceAll('\n', ' ');
