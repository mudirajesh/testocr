import 'package:flutter/foundation.dart';

import '../models/scan_record.dart';
import '../utils/scan_metrics.dart';
import 'accuracy_report.dart';

/// What the tester typed on the setup form.
class SampleSetup {
  const SampleSetup({
    required this.label,
    required this.expectedBatch,
    required this.expectedGtin,
    required this.tags,
    required this.attempts,
  });

  final String label;

  /// The batch number printed on the pack (compared exactly).
  final String expectedBatch;
  final String? expectedGtin;
  final List<String> tags;

  /// How many scans to make of this sample.
  final int attempts;
}

/// Turns one accepted scan into an [AttemptRecord]. [correct] is an exact,
/// case-sensitive comparison of the extracted batch with the expected one.
AttemptRecord attemptFromScan({
  required int attemptNumber,
  required String expectedBatch,
  required ScanRecord record,
  required String status,
  required List<String> warnings,
  required ScanMetrics? metrics,
}) {
  return AttemptRecord(
    attemptNumber: attemptNumber,
    extractedBatch: record.batchNumber,
    extractedGtin: record.gtin,
    correct: isExactBatchMatch(expectedBatch, record.batchNumber),
    scanToResultMs: metrics?.consensusMs,
    confidence: record.confidenceScore,
    status: status,
    warnings: warnings,
    rawVisible: record.rawBarcode.replaceAll('\u001D', '<GS>'),
  );
}

/// The samples collected so far in one test session.
class AccuracySession extends ChangeNotifier {
  final List<SampleResult> _samples = [];

  List<SampleResult> get samples => List.unmodifiable(_samples);
  int get sampleCount => _samples.length;
  SessionSummary get summary => SessionSummary.from(_samples);

  void addSample(SampleResult sample) {
    _samples.add(sample);
    notifyListeners();
  }

  void clear() {
    _samples.clear();
    notifyListeners();
  }
}
