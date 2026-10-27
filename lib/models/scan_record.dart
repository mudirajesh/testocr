import 'package:uuid/uuid.dart';

import '../utils/constants.dart';

enum ScanStatus { pass, alert }

const _uuid = Uuid();

/// One saved barcode scan.
class ScanRecord {
  const ScanRecord({
    required this.id,
    required this.rawBarcode,
    required this.barcodeFormat,
    this.batchNumber,
    this.gtin,
    this.expiryDate,
    this.serialNumber,
    required this.scanTimestamp,
    this.confidenceScore,
    this.isValid = true,
    this.imagePath,
    this.medicineName,
    this.strength,
    this.isOcr = false,
    this.verifiedByUser = false,
  });

  /// New record with a generated UUID v4 and `scanTimestamp` of now.
  factory ScanRecord.create({
    required String rawBarcode,
    required String barcodeFormat,
    String? batchNumber,
    String? gtin,
    String? expiryDate,
    String? serialNumber,
    DateTime? scanTimestamp,
    double? confidenceScore,
    bool isValid = true,
    String? imagePath,
    String? medicineName,
    String? strength,
    bool isOcr = false,
    bool verifiedByUser = false,
  }) {
    return ScanRecord(
      id: _uuid.v4(),
      rawBarcode: rawBarcode,
      barcodeFormat: barcodeFormat,
      batchNumber: batchNumber,
      gtin: gtin,
      expiryDate: expiryDate,
      serialNumber: serialNumber,
      scanTimestamp: scanTimestamp ?? DateTime.now(),
      confidenceScore: confidenceScore,
      isValid: isValid,
      imagePath: imagePath,
      medicineName: medicineName,
      strength: strength,
      isOcr: isOcr,
      verifiedByUser: verifiedByUser,
    );
  }

  factory ScanRecord.fromMap(Map<String, Object?> map) {
    return ScanRecord(
      id: map[kColId]! as String,
      rawBarcode: map[kColRawBarcode]! as String,
      barcodeFormat: map[kColBarcodeFormat]! as String,
      batchNumber: map[kColBatchNumber] as String?,
      gtin: map[kColGtin] as String?,
      expiryDate: map[kColExpiryDate] as String?,
      serialNumber: map[kColSerialNumber] as String?,
      scanTimestamp: DateTime.parse(map[kColScanTimestamp]! as String)
          .toLocal(),
      confidenceScore: (map[kColConfidenceScore] as num?)?.toDouble(),
      isValid: (map[kColIsValid] as int? ?? 1) == 1,
      imagePath: map[kColImagePath] as String?,
      medicineName: map[kColMedicineName] as String?,
      strength: map[kColStrength] as String?,
      isOcr: (map[kColIsOcr] as int? ?? 0) == 1,
      verifiedByUser: (map[kColVerifiedByUser] as int? ?? 0) == 1,
    );
  }

  final String id;
  final String rawBarcode;

  /// GS1-128, DataMatrix, QR, EAN-13, EAN-8 or MANUAL.
  final String barcodeFormat;

  /// AI 10.
  final String? batchNumber;

  /// AI 01.
  final String? gtin;

  /// AI 17, stored as YYMMDD.
  final String? expiryDate;

  /// AI 21.
  final String? serialNumber;
  final DateTime scanTimestamp;

  /// 0.0 to 1.0, null for manual entries.
  final double? confidenceScore;

  /// True = parsed OK; false = parse failed or low confidence.
  final bool isValid;

  /// Local file path to captured photo, if available.
  final String? imagePath;

  /// Matched or extracted medicine name.
  final String? medicineName;

  /// Medicine strength (e.g. "500 mg").
  final String? strength;

  /// Whether data was recovered via fallback OCR.
  final bool isOcr;

  /// Whether user confirmed medicine name & strength.
  final bool verifiedByUser;

  ScanStatus get status => isValid ? ScanStatus.pass : ScanStatus.alert;

  /// Expiry as DD/MM/YYYY (assumes 20YY; day 00 = last day of the month).
  /// Null when missing or not a valid YYMMDD date.
  String? get expiryDisplay {
    final e = expiryDate;
    if (e == null || !RegExp(r'^\d{6}$').hasMatch(e)) return null;

    final year = 2000 + int.parse(e.substring(0, 2));
    final month = int.parse(e.substring(2, 4));
    var day = int.parse(e.substring(4, 6));
    if (month < 1 || month > 12) return null;

    final lastDay = DateTime(year, month + 1, 0).day;
    if (day == 0) day = lastDay;
    if (day > lastDay) return null;

    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(day)}/${two(month)}/$year';
  }

  /// e.g. 0.8 -> "80%". Null when there is no score.
  String? get confidencePercent {
    final c = confidenceScore;
    if (c == null) return null;
    return '${(c * 100).round()}%';
  }

  Map<String, Object?> toMap() => {
    kColId: id,
    kColRawBarcode: rawBarcode,
    kColBarcodeFormat: barcodeFormat,
    kColBatchNumber: batchNumber,
    kColGtin: gtin,
    kColExpiryDate: expiryDate,
    kColSerialNumber: serialNumber,
    // Stored as UTC at millisecond precision so strings sort chronologically.
    kColScanTimestamp: DateTime.fromMillisecondsSinceEpoch(
      scanTimestamp.millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String(),
    kColConfidenceScore: confidenceScore,
    kColIsValid: isValid ? 1 : 0,
    kColImagePath: imagePath,
    kColMedicineName: medicineName,
    kColStrength: strength,
    kColIsOcr: isOcr ? 1 : 0,
    kColVerifiedByUser: verifiedByUser ? 1 : 0,
  };

  ScanRecord copyWith({
    String? id,
    String? rawBarcode,
    String? barcodeFormat,
    String? batchNumber,
    String? gtin,
    String? expiryDate,
    String? serialNumber,
    DateTime? scanTimestamp,
    double? confidenceScore,
    bool? isValid,
    String? imagePath,
    String? medicineName,
    String? strength,
    bool? isOcr,
    bool? verifiedByUser,
  }) {
    return ScanRecord(
      id: id ?? this.id,
      rawBarcode: rawBarcode ?? this.rawBarcode,
      barcodeFormat: barcodeFormat ?? this.barcodeFormat,
      batchNumber: batchNumber ?? this.batchNumber,
      gtin: gtin ?? this.gtin,
      expiryDate: expiryDate ?? this.expiryDate,
      serialNumber: serialNumber ?? this.serialNumber,
      scanTimestamp: scanTimestamp ?? this.scanTimestamp,
      confidenceScore: confidenceScore ?? this.confidenceScore,
      isValid: isValid ?? this.isValid,
      imagePath: imagePath ?? this.imagePath,
      medicineName: medicineName ?? this.medicineName,
      strength: strength ?? this.strength,
      isOcr: isOcr ?? this.isOcr,
      verifiedByUser: verifiedByUser ?? this.verifiedByUser,
    );
  }

  @override
  bool operator ==(Object other) => other is ScanRecord && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
