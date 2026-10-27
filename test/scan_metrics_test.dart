import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/utils/constants.dart';
import 'package:gs1scan/utils/scan_metrics.dart';

void main() {
  group('ScanMetrics', () {
    test('formats the summary line', () {
      const metrics = ScanMetrics(
        firstDetectionMs: 420,
        consensusMs: 780,
        averageFrameMs: 95.2,
      );
      expect(
        metrics.format(),
        'SCAN_METRICS first=420ms consensus=780ms avgFrame=95ms',
      );
    });

    test('rounds the frame time', () {
      const metrics = ScanMetrics(
        firstDetectionMs: 0,
        consensusMs: 0,
        averageFrameMs: 94.6,
      );
      expect(metrics.format(), endsWith('avgFrame=95ms'));
    });

    test('is logged in debug and profile builds, never in release', () {
      expect(scanMetricsLoggingEnabled(debug: true, profile: false), isTrue);
      expect(scanMetricsLoggingEnabled(debug: false, profile: true), isTrue);
      expect(scanMetricsLoggingEnabled(debug: false, profile: false), isFalse);
    });
  });

  group('raw barcode logging', () {
    test('kLogRawBarcodes is debug-only', () {
      expect(kLogRawBarcodes, kDebugLogRaw && kDebugMode);
      if (kReleaseMode || kProfileMode) {
        expect(kLogRawBarcodes, isFalse);
      }
    });

    test('no release code path prints scanned values', () {
      // Every print/debugPrint statement in lib/ is checked: one that mentions
      // a raw barcode value must sit behind kLogRawBarcodes.
      final offenders = <String>[];
      final statement = RegExp(
        r'(debugPrint|print)\(([^;]*?)\);',
        dotAll: true,
      );
      final rawWords = RegExp(
        r'rawValue|rawBarcode|\.raw\b|picked\.raw|consensus\.raw|\braw\b',
      );

      for (final file in Directory('lib').listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final text = file.readAsStringSync();
        for (final match in statement.allMatches(text)) {
          final body = match.group(2)!;
          if (!rawWords.hasMatch(body)) continue;
          final before = text.substring(
            (match.start - 160).clamp(0, text.length),
            match.start,
          );
          if (!before.contains('kLogRawBarcodes')) {
            offenders.add('${file.path}: ${match.group(0)}');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });
}
