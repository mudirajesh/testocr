import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/scan_record.dart';
import '../services/database_service.dart';

/// Debug builds only: fills the database with realistic scans so paging,
/// search and the list design can be tested. Does nothing in release builds.
Future<void> seedDebugScans(DatabaseService db, {int count = 120}) async {
  if (!kDebugMode) return;

  final random = Random(2026);
  final now = DateTime.now();
  const prefixes = ['BN', 'LOT', 'AX', 'MK', 'PH'];
  const suffixes = ['X', 'K', 'Q', 'T', 'E'];
  const formats = ['DataMatrix', 'GS1-128'];

  String gtinWithCheckDigit() {
    final digits = [for (var i = 0; i < 13; i++) random.nextInt(10)];
    var sum = 0;
    for (var i = 0; i < 13; i++) {
      sum += digits[12 - i] * (i.isEven ? 3 : 1);
    }
    return '${digits.join()}${(10 - sum % 10) % 10}';
  }

  final records = <ScanRecord>[];
  for (var i = 0; i < count; i++) {
    final valid = random.nextInt(100) >= 15; // about 15% alerts
    final format = formats[random.nextInt(formats.length)];
    final batch =
        '${prefixes[random.nextInt(prefixes.length)]}'
        '${2023 + random.nextInt(3)}'
        '${suffixes[random.nextInt(suffixes.length)]}'
        '${100 + random.nextInt(900)}';
    final gtin = gtinWithCheckDigit();
    final expiry =
        '${27 + random.nextInt(3)}'
        '${(1 + random.nextInt(12)).toString().padLeft(2, '0')}'
        '${(1 + random.nextInt(28)).toString().padLeft(2, '0')}';

    // Spread over the last 30 days, newest first.
    final minutesAgo = (i / count * 30 * 24 * 60).round() + random.nextInt(30);

    records.add(
      ScanRecord.create(
        rawBarcode: '01${gtin}17${expiry}10$batch',
        barcodeFormat: format,
        batchNumber: valid || random.nextBool() ? batch : null,
        gtin: valid || random.nextBool() ? gtin : null,
        expiryDate: valid ? expiry : null,
        scanTimestamp: now.subtract(Duration(minutes: minutesAgo)),
        confidenceScore: valid ? 0.6 + random.nextInt(5) / 10 : 0.2,
        isValid: valid,
      ),
    );
  }
  await db.insertAll(records);
}
