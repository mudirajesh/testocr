// Pure validation helpers for GS1 element strings. No Flutter imports.

final _digitsOnly = RegExp(r'^\d+$');
final _batchSafeChars = RegExp(r'^[A-Za-z0-9.\-]+$');

bool isDigitsOnly(String v) => v.isNotEmpty && _digitsOnly.hasMatch(v);

/// GS1 modulo-10 check digit over a 14-digit GTIN.
///
/// Walking right to left over the 13 payload digits, weights alternate
/// 3, 1, 3, 1 ...; the check digit is (10 - sum % 10) % 10.
bool isValidGtinCheckDigit(String gtin14) {
  if (gtin14.length != 14 || !isDigitsOnly(gtin14)) return false;
  var sum = 0;
  for (var i = 0; i < 13; i++) {
    final digit = gtin14.codeUnitAt(12 - i) - 0x30;
    sum += digit * (i.isEven ? 3 : 1);
  }
  final expected = (10 - sum % 10) % 10;
  return expected == gtin14.codeUnitAt(13) - 0x30;
}

/// YYMMDD, century assumed 20YY. Day "00" is legal and means "end of month".
bool isValidGs1Date(String yymmdd) {
  if (yymmdd.length != 6 || !isDigitsOnly(yymmdd)) return false;
  final year = 2000 + int.parse(yymmdd.substring(0, 2));
  final month = int.parse(yymmdd.substring(2, 4));
  final day = int.parse(yymmdd.substring(4, 6));
  if (month < 1 || month > 12) return false;
  if (day == 0) return true;
  // Day 0 of the next month is the last day of this one, leap years included.
  final lastDay = DateTime(year, month + 1, 0).day;
  return day <= lastDay;
}

bool isValidBatch(String v) => v.isNotEmpty && v.length <= 20;

final _standaloneBatchUrl = RegExp(r'^(https?:|www\.)', caseSensitive: false);
final _standaloneAllDigits = RegExp(r'^\d+$');
final _standaloneParenAi = RegExp(r'^\(\d{2,4}\)');
final _standaloneHasAlnum = RegExp(r'[A-Za-z0-9]');
final _standaloneGs1Gtin = RegExp(r'^01\d{14}');
final _standaloneGs1Sscc = RegExp(r'^00\d{18}');
final _gs1BatchMarker = RegExp(
  r'(?:\(10\)|[\u001D|]10|[^\d]10|^10)[A-Za-z0-9.\-]',
);
final _gs1ConcatenatedBatch = RegExp(r'01\d{14}(?:17\d{6})?10[A-Za-z0-9.\-]');

/// A barcode that is itself a lot/batch code, not a GS1 element string
/// and not a retail GTIN/EAN/UPC.
bool isStandaloneBatch(String v) {
  if (v.isEmpty || v.length < 2 || v.length > 20) return false;
  if (!_standaloneHasAlnum.hasMatch(v)) return false;
  if (_standaloneBatchUrl.hasMatch(v)) return false;
  if (_standaloneParenAi.hasMatch(v)) return false;
  if (_standaloneGs1Gtin.hasMatch(v) || _standaloneGs1Sscc.hasMatch(v)) {
    return false;
  }
  if (_standaloneAllDigits.hasMatch(v) &&
      (v.length == 8 || v.length == 12 || v.length == 13 || v.length == 14)) {
    return false;
  }
  return true;
}

/// True when [raw] is a GS1 string that carries AI 10, or a standalone lot.
bool looksLikeBatchPayload(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return false;
  if (_gs1BatchMarker.hasMatch(v) || _gs1ConcatenatedBatch.hasMatch(v)) {
    return true;
  }
  return isStandaloneBatch(v);
}

/// Warning (never an error) when a batch holds characters outside the common
/// set. GS1 allows more, and real lots do contain "/" or "_".
String? batchCharWarning(String v) {
  if (v.isEmpty || _batchSafeChars.hasMatch(v)) return null;
  return 'Batch/lot contains unusual characters: $v';
}

bool isValidSerial(String v) => v.isNotEmpty && v.length <= 20;

String normalizeWhitespaceCommon(String v) => v.trim();
