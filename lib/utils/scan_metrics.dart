import 'package:flutter/foundation.dart';

/// Timing of one accepted scan, for the speed check (target: under 2 s from
/// the first detection to the result).
class ScanMetrics {
  const ScanMetrics({
    required this.firstDetectionMs,
    required this.consensusMs,
    required this.averageFrameMs,
  });

  /// Scanner started (or restarted) until the first barcode was seen.
  final int firstDetectionMs;

  /// First detection until the result was accepted. This is the
  /// "scan-to-result" time.
  final int consensusMs;

  /// Average duration of one ML Kit call.
  final double averageFrameMs;

  /// e.g. "SCAN_METRICS first=420ms consensus=780ms avgFrame=95ms".
  String format() =>
      'SCAN_METRICS first=${firstDetectionMs}ms consensus=${consensusMs}ms '
      'avgFrame=${averageFrameMs.round()}ms';
}

/// Metrics are logged in debug and profile builds only; release builds log
/// nothing.
bool scanMetricsLoggingEnabled({
  bool debug = kDebugMode,
  bool profile = kProfileMode,
}) => debug || profile;
