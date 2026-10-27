final _digitsOnly = RegExp(r'^\d+$');

/// One text cell for a CSV that people will open in a spreadsheet; null ->
/// empty. Pure Dart.
///
/// Spreadsheet safety (the value is untrusted scanned data):
///  * Leading zeros: with [protectDigits] (callers pass their
///    kCsvProtectLeadingZeros setting) an all-digit value is written as ="0123" so Excel does
///    not turn 08901234567890 into 8901234567890. This wins over the formula
///    guard below for those cells.
///  * Formula injection: a cell starting with = + - @ tab or CR would be run as
///    a formula by Excel/Sheets (e.g. =HYPERLINK(...) in a crafted barcode).
///    A leading single quote makes it plain text.
String csvSafeText(String? value, {bool protectDigits = false}) {
  if (value == null || value.isEmpty) return '';
  if (protectDigits && _digitsOnly.hasMatch(value)) return '="$value"';
  const dangerous = ['=', '+', '-', '@', '\t', '\r'];
  if (dangerous.any(value.startsWith)) return "'$value";
  return value;
}
