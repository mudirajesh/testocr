import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/scan_record.dart';
import 'package:gs1scan/services/csv_export_service.dart';
import 'package:gs1scan/utils/constants.dart';

ScanRecord rec({
  String id = 'id',
  String raw = '(01)08901234567890',
  String format = 'DataMatrix',
  String? batch = 'BN2024X981',
  String? gtin = '08901234567890',
  String? expiry = '261231',
  String? serial,
  DateTime? at,
  double? confidence = 0.6,
  bool isValid = true,
}) => ScanRecord(
  id: id,
  rawBarcode: raw,
  barcodeFormat: format,
  batchNumber: batch,
  gtin: gtin,
  expiryDate: expiry,
  serialNumber: serial,
  scanTimestamp: at ?? DateTime(2026, 9, 29, 14, 32, 5),
  confidenceScore: confidence,
  isValid: isValid,
);

/// Parses the output back with the csv package (all values as strings).
List<List<dynamic>> parse(String text) => Csv().decode(text);

void main() {
  test('header row equals kCsvHeaders in order', () {
    final rows = parse(buildCsv([]));
    expect(rows.length, 1);
    expect(rows.first, kCsvHeaders);
    expect(kCsvHeaders, [
      'Sr. No.',
      'Batch Number',
      'GTIN',
      'Expiry Date',
      'Serial Number',
      'Raw Barcode',
      'Barcode Format',
      'Scan Date & Time',
      'Valid',
      'Confidence',
    ]);
  });

  test('Sr. No. counts from 1 and rows keep the order given', () {
    final rows = parse(
      buildCsv([
        rec(id: 'c', batch: 'THIRD'),
        rec(id: 'a', batch: 'FIRST'),
        rec(id: 'b', batch: 'SECOND'),
      ]),
    );
    expect(rows.length, 4);
    expect(rows.skip(1).map((r) => r[0].toString()), ['1', '2', '3']);
    expect(rows.skip(1).map((r) => r[1]), ['THIRD', 'FIRST', 'SECOND']);
  });

  test('null fields export as empty strings', () {
    final row = parse(
      buildCsv([
        rec(
          batch: null,
          gtin: null,
          expiry: null,
          serial: null,
          confidence: null,
        ),
      ]),
    )[1];
    expect(row[1], ''); // batch
    expect(row[2], ''); // gtin
    expect(row[3], ''); // expiry
    expect(row[4], ''); // serial
    expect(row[9], ''); // confidence
  });

  test('values are exported exactly as stored, never trimmed', () {
    final row = parse(buildCsv([rec(batch: ' BN 1 ', format: 'GS1-128')]))[1];
    expect(row[1], ' BN 1 ');
    expect(row[6], 'GS1-128');
  });

  test('expiry shows DD/MM/YYYY; an invalid one exports the raw YYMMDD', () {
    final rows = parse(
      buildCsv([
        rec(expiry: '261231'),
        rec(expiry: '261200'),
        rec(expiry: '261301'),
      ]),
    );
    expect(rows[1][3], '31/12/2026');
    expect(rows[2][3], '31/12/2026'); // day 00 = end of month
    expect(rows[3][3], '261301');
  });

  test('scan time, Valid and Confidence formats', () {
    final rows = parse(
      buildCsv([
        rec(at: DateTime(2026, 1, 5, 9, 3, 7), isValid: true, confidence: 0.6),
        rec(isValid: false, confidence: 1.0),
      ]),
    );
    expect(rows[1][7], '05/01/2026 09:03:07');
    expect(rows[1][8], 'Yes');
    expect(rows[1][9], '60%');
    expect(rows[2][8], 'No');
    expect(rows[2][9], '100%');
  });

  test('commas, quotes and newlines are escaped and round-trip', () {
    const tricky = 'a,b "quoted"\nsecond line,\r\nthird';
    final text = buildCsv([rec(raw: tricky, batch: 'B,1 "x"')]);

    // The raw cell is quoted, with doubled inner quotes.
    expect(text, contains('"a,b ""quoted""'));
    final row = parse(text)[1];
    expect(row[5], tricky);
    expect(row[1], 'B,1 "x"');
    expect(row.length, kCsvHeaders.length);
  });

  test('the GS control character exports as <GS>', () {
    final row = parse(
      buildCsv([rec(raw: '0108901234567890\u001D10BN1\u001D21S1')]),
    )[1];
    expect(row[5], '0108901234567890<GS>10BN1<GS>21S1');
    expect(row[5], isNot(contains('\u001D')));
  });

  test('formula injection: dangerous starts get a leading quote', () {
    final row = parse(
      buildCsv([rec(batch: '=SUM(A1)', serial: '+1', raw: '-1', format: '@x')]),
    )[1];
    expect(row[1], "'=SUM(A1)");
    expect(row[4], "'+1");
    expect(row[5], "'-1");
    expect(row[6], "'@x");

    final tabbed = parse(buildCsv([rec(batch: '\tcmd'), rec(batch: '\rcmd')]));
    expect(tabbed[1][1], "'\tcmd");
    expect(tabbed[2][1], "'\rcmd");
  });

  test('safe values are not given a quote', () {
    final row = parse(buildCsv([rec(batch: 'BN-1=2', serial: 'A-1')]))[1];
    expect(row[1], 'BN-1=2');
    expect(row[4], 'A-1');
  });

  test('leading zeros: digit-only GTIN and serial are written as ="..."', () {
    final row = parse(
      buildCsv([rec(gtin: '08901234567890', serial: '0042')]),
    )[1];
    expect(row[2], '="08901234567890"');
    expect(row[4], '="0042"');
  });

  test('a non-numeric serial is unchanged', () {
    final row = parse(buildCsv([rec(serial: 'SER-0042')]))[1];
    expect(row[4], 'SER-0042');
  });

  test('digit protection wins over the formula guard', () {
    // A digit-only value never starts with a formula character, so this just
    // pins the ="..." form; a value like "-5" is not all digits and is quoted.
    final row = parse(buildCsv([rec(gtin: '-5', serial: '00')]))[1];
    expect(row[2], "'-5");
    expect(row[4], '="00"');
  });

  test('with protection off the GTIN is plain', () {
    final row = parse(
      buildCsv([rec(gtin: '08901234567890')], protectLeadingZeros: false),
    )[1];
    expect(row[2], '08901234567890');
  });

  test('lines end with CRLF', () {
    final text = buildCsv([rec(), rec()]);
    expect(text.split('\r\n').length, 3); // header + 2 rows
    expect(text.replaceAll('\r\n', '').contains('\n'), isFalse);
    expect(RegExp(r'(?<!\r)\n').hasMatch(text), isFalse);
  });

  test('non-ASCII text survives', () {
    final row = parse(buildCsv([rec(batch: 'बैच-१२३ é')]))[1];
    expect(row[1], 'बैच-१२३ é');
  });
}
