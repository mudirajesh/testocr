import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/gs1_parse_result.dart';
import 'package:gs1scan/services/gs1_parser_service.dart';
import 'package:gs1scan/utils/gs1_constants.dart';

const parser = Gs1ParserService();

/// The real GS character a scanner emits for FNC1.
const gs = '\u001D';

/// A GTIN-14 with a correct check digit.
const validGtin = '08901234567890';

/// Appends the correct GS1 modulo-10 check digit to 13 digits.
String gtinWith(String first13) {
  assert(first13.length == 13, 'need 13 digits');
  var sum = 0;
  for (var i = 0; i < 13; i++) {
    final digit = first13.codeUnitAt(12 - i) - 0x30;
    sum += digit * (i.isEven ? 3 : 1);
  }
  return '$first13${(10 - sum % 10) % 10}';
}

bool _hasWarning(List<String> warnings, String fragment) =>
    warnings.any((w) => w.contains(fragment));

void main() {
  // Machine-readable payload reused by the separator cases.
  const payloadBeforeSeparator =
      '01${validGtin}17261231'
      '10ABC123';
  const payloadAfterSeparator = '21SER456';

  void expectStandardFields(Gs1ParseResult r) {
    expect(r.gtin, validGtin);
    expect(r.expiryYymmdd, '261231');
    expect(r.batchNumber, 'ABC123');
    expect(r.serialNumber, 'SER456');
    expect(r.errors, isEmpty);
    expect(r.isGs1, isTrue);
    expect(r.isValid, isTrue);
  }

  test('1. standard (01)(17)(10)(21) with a GS between variable fields', () {
    final r = parser.parse('$payloadBeforeSeparator$gs$payloadAfterSeparator');
    expectStandardFields(r);
    expect(r.fields.map((f) => f.ai), ['01', '17', '10', '21']);
    expect(r.symbologyIdentifier, isNull);
    expect(r.corrections, isEmpty);
  });

  test('2. ]d2 prefix is stripped', () {
    final r = parser.parse(
      ']d2$payloadBeforeSeparator$gs$payloadAfterSeparator',
    );
    expectStandardFields(r);
    expect(r.symbologyIdentifier, ']d2');
  });

  test('3. ]C1 prefix is stripped', () {
    final r = parser.parse(
      ']C1$payloadBeforeSeparator$gs$payloadAfterSeparator',
    );
    expectStandardFields(r);
    expect(r.symbologyIdentifier, ']C1');
  });

  test(r'4. separator as the literal text \x1D', () {
    final r = parser.parse(
      '$payloadBeforeSeparator${r'\x1D'}$payloadAfterSeparator',
    );
    expectStandardFields(r);
  });

  test('5. separator as ~', () {
    final r = parser.parse('$payloadBeforeSeparator~$payloadAfterSeparator');
    expectStandardFields(r);
  });

  test('6. separator as <GS>', () {
    final r = parser.parse('$payloadBeforeSeparator<GS>$payloadAfterSeparator');
    expectStandardFields(r);
  });

  test('7. missing FNC1 after a 20-character batch splits at max length', () {
    const batch20 = 'B1234567890123456789';
    expect(batch20.length, 20);
    final r = parser.parse('01${validGtin}10${batch20}21SER1');

    expect(r.batchNumber, batch20);
    expect(r.serialNumber, 'SER1');
    expect(_hasWarning(r.warnings, 'possible missing FNC1 separator'), isTrue);
    expect(r.isValid, isTrue);
  });

  test('8. batch as the last field with no trailing separator', () {
    final r = parser.parse('01${validGtin}10ABC123');
    expect(r.batchNumber, 'ABC123');
    expect(r.serialNumber, isNull);
    expect(r.isValid, isTrue);
  });

  test('9. GTIN only: warns about the missing batch but stays valid', () {
    final r = parser.parse('01$validGtin');
    expect(r.gtin, validGtin);
    expect(r.batchNumber, isNull);
    expect(_hasWarning(r.warnings, 'No batch/lot number'), isTrue);
    expect(r.isValid, isTrue);
  });

  test('10. letter O in the GTIN is corrected, with the index recorded', () {
    final r = parser.parse('01O89O1234567890');

    expect(r.gtin, validGtin);
    expect(r.isValid, isTrue);
    expect(r.hasCorrections, isTrue);
    expect(r.corrections.length, 2);
    expect(r.corrections.map((c) => c.index), [0, 3]);
    expect(r.corrections.every((c) => c.ai == kAiGtin), isTrue);
    expect(r.corrections.every((c) => c.from == 'O' && c.to == '0'), isTrue);
  });

  test('11. o, I and l in the GTIN are all corrected', () {
    final clean = gtinWith('0101010101010');
    var zeros = 0;
    var ones = 0;
    final messy = clean.split('').map((c) {
      if (c == '0') return (zeros++).isEven ? 'O' : 'o';
      if (c == '1') return (ones++).isEven ? 'I' : 'l';
      return c;
    }).join();

    final r = parser.parse('01$messy');

    expect(r.gtin, clean);
    expect(r.isValid, isTrue);
    expect(r.corrections.map((c) => c.from).toSet(), {'O', 'o', 'I', 'l'});
    expect(r.corrections.map((c) => c.to).toSet(), {'0', '1'});
  });

  test('12. letter O in the expiry date is corrected', () {
    final r = parser.parse('01${validGtin}172612O1');

    expect(r.expiryYymmdd, '261201');
    expect(r.isValid, isTrue);
    expect(
      r.corrections.any(
        (c) => c.ai == kAiExpiry && c.from == 'O' && c.to == '0',
      ),
      isTrue,
    );
  });

  test('13. expiry day 00 is valid, leap year included', () {
    final december = parser.parse('01${validGtin}17261200');
    expect(december.expiryYymmdd, '261200');
    expect(december.errors, isEmpty);
    expect(december.isValid, isTrue);

    final leapFebruary = parser.parse('01${validGtin}17280200');
    expect(leapFebruary.expiryYymmdd, '280200');
    expect(leapFebruary.isValid, isTrue);
  });

  test('14. month 13 in the expiry is an error', () {
    final r = parser.parse('01${validGtin}17261301');
    expect(r.errors, contains('AI 17: invalid date'));
    expect(r.isValid, isFalse);
    expect(r.isGs1, isTrue);
  });

  test('15. a wrong GTIN check digit is an error', () {
    final r = parser.parse('0108901234567891');
    expect(r.errors, contains('GTIN check digit invalid'));
    expect(r.isValid, isFalse);
  });

  test('16. embedded spaces in the GTIN are stripped', () {
    final machine = parser.parse('010890 1234 5678 90');
    expect(machine.gtin, validGtin);
    expect(machine.isValid, isTrue);

    final humanReadable = parser.parse('(01)0890 1234 5678 90');
    expect(humanReadable.gtin, validGtin);
    expect(humanReadable.isValid, isTrue);
  });

  test('17. a space inside the batch is stripped unless preserved', () {
    const raw = '01${validGtin}10BN 2024';

    final stripped = parser.parse(raw);
    expect(stripped.batchNumber, 'BN2024');
    expect(stripped.isValid, isTrue);

    final preserved = parser.parse(raw, preserveBatchSpaces: true);
    expect(preserved.batchNumber, 'BN 2024');
    expect(preserved.isValid, isTrue);
  });

  test('18. O/0 in the batch are flagged, never rewritten', () {
    final r = parser.parse('01${validGtin}10BO2024O98');

    expect(r.batchNumber, 'BO2024O98');
    expect(r.ambiguousBatchIndices, [1, 3, 6]);
    expect(r.hasAmbiguousChars, isTrue);
    expect(_hasWarning(r.warnings, 'can be confused (O/0)'), isTrue);
    expect(r.corrections, isEmpty);
    expect(r.isValid, isTrue);
  });

  test('19. a batch longer than 20 characters is an error', () {
    final longBatch = 'B' * 21;
    final r = parser.parse('01${validGtin}10$longBatch${gs}21S1');

    expect(r.batchNumber, longBatch);
    expect(r.errors, contains('AI 10: invalid batch/lot number'));
    expect(r.isValid, isFalse);
  });

  test('20. an alphanumeric serial number is parsed', () {
    final r = parser.parse('01${validGtin}10LOT1${gs}21ABC-123');
    expect(r.serialNumber, 'ABC-123');
    expect(r.isValid, isTrue);
  });

  test('21. a 200+ character concatenation keeps order and first values', () {
    final buffer = StringBuffer();
    for (var n = 0; n < 6; n++) {
      buffer
        ..write('01$validGtin')
        ..write('10BATCH00$n')
        ..write(gs)
        ..write('21SER00$n')
        ..write(gs);
    }
    final raw = buffer.toString();
    expect(raw.length, greaterThan(200));

    final r = parser.parse(raw);

    expect(r.fields.length, 18);
    expect(r.fields.map((f) => f.ai).toList(), [
      for (var n = 0; n < 6; n++) ...['01', '10', '21'],
    ]);
    expect(r.fields[1].value, 'BATCH000');
    expect(r.fields[4].value, 'BATCH001');
    expect(r.batchNumber, 'BATCH000');
    expect(r.serialNumber, 'SER000');
    expect(r.gtin, validGtin);
    expect(_hasWarning(r.warnings, 'Duplicate AI 10'), isTrue);
    expect(_hasWarning(r.warnings, 'Duplicate AI 21'), isTrue);
    expect(_hasWarning(r.warnings, 'Duplicate AI 01'), isTrue);
  });

  test('22. non-GS1 input is rejected and the raw string is kept', () {
    const url = 'https://example.com/abc';
    final r = parser.parse(url);

    expect(r.isGs1, isFalse);
    expect(r.isValid, isFalse);
    expect(r.batchNumber, isNull);
    expect(r.gtin, isNull);
    expect(r.rawInput, url);
    expect(r.errors, contains('Unrecognised barcode format'));
  });

  test('23. empty and whitespace-only input', () {
    for (final raw in ['', '   ', '\n\t']) {
      final r = parser.parse(raw);
      expect(r.errors, ['Empty barcode']);
      expect(r.isValid, isFalse);
      expect(r.isGs1, isFalse);
      expect(r.rawInput, raw);
    }
  });

  test('24. human-readable form matches the machine form', () {
    final human = parser.parse('(01)08901234567890(17)261231(10)BN2024X981');
    final machine = parser.parse('01089012345678901726123110BN2024X981');

    expect(human.byAi, machine.byAi);
    expect(human.gtin, validGtin);
    expect(human.expiryYymmdd, '261231');
    expect(human.batchNumber, 'BN2024X981');
    expect(human.isValid, isTrue);
    expect(machine.isValid, isTrue);
  });

  test('25. S/B substitution only when it makes the check digit pass', () {
    final applied = parser.parse('0108901234S67890');
    expect(applied.gtin, validGtin);
    expect(applied.isValid, isTrue);
    expect(
      applied.corrections.any(
        (c) => c.from == 'S' && c.to == '5' && c.index == 8,
      ),
      isTrue,
    );

    final notApplied = parser.parse('0108901234S67891');
    expect(notApplied.corrections, isEmpty);
    expect(notApplied.gtin, '08901234S67891');
    expect(notApplied.errors, contains('GTIN must be 14 digits'));
    expect(notApplied.isValid, isFalse);
  });

  test('26. EAN-13 is padded to a GTIN-14 and flagged as retail', () {
    final r = parser.parse('8901234567890', barcodeFormat: kFormatEan13);

    expect(r.gtin, validGtin);
    expect(r.batchNumber, isNull);
    expect(r.isGs1, isTrue);
    expect(r.isValid, isTrue);
    expect(
      _hasWarning(r.warnings, 'Retail barcode: no batch/lot data'),
      isTrue,
    );
  });

  test('27. production date (11) and count (30) are parsed', () {
    final r = parser.parse('01${validGtin}112601013012');

    expect(r.productionDate, '260101');
    expect(r.count, '12');
    expect(r.isValid, isTrue);
  });

  test('28. whitespace around the whole raw string is ignored', () {
    final r = parser.parse(
      '  $payloadBeforeSeparator$gs$payloadAfterSeparator \n',
    );
    expectStandardFields(r);
  });

  test('substitutions are never applied to batch or serial values', () {
    final r = parser.parse('01${validGtin}10BOIL${gs}21S1B2');

    expect(r.batchNumber, 'BOIL');
    expect(r.serialNumber, 'S1B2');
    expect(r.corrections, isEmpty);
    expect(r.isValid, isTrue);
  });

  test('a standalone Code 39 lot code is the batch number', () {
    final r = parser.parse('BN2024X981', barcodeFormat: 'code39');
    expect(r.batchNumber, 'BN2024X981');
    expect(r.gtin, isNull);
    expect(r.isGs1, isTrue);
    expect(r.isValid, isTrue);
  });

  test('a lot starting with 10 is kept whole, not walked as AI 10', () {
    final r = parser.parse('10ABC123', barcodeFormat: 'code39');
    expect(r.batchNumber, '10ABC123');
    expect(r.gtin, isNull);
    expect(r.isValid, isTrue);
  });

  test('GS1 concatenated data is not rewritten as a standalone lot', () {
    final r = parser.parse(
      '01089012345678901726123110BN2024X981',
      barcodeFormat: 'dataMatrix',
    );
    expect(r.gtin, validGtin);
    expect(r.expiryYymmdd, '261231');
    expect(r.batchNumber, 'BN2024X981');
    expect(r.isValid, isTrue);
  });

  test('a standalone ITF lot code is the batch number', () {
    final r = parser.parse('LOT-2024A', barcodeFormat: 'itf');
    expect(r.batchNumber, 'LOT-2024A');
    expect(r.isValid, isTrue);
  });

  test('a URL is still unrecognised', () {
    final r = parser.parse('https://example.com', barcodeFormat: 'qrCode');
    expect(r.batchNumber, isNull);
    expect(r.isGs1, isFalse);
    expect(r.errors, contains('Unrecognised barcode format'));
  });

  test('parse never throws on hostile input', () {
    for (final raw in [
      '01',
      '0101',
      '17',
      '10',
      '|||',
      ']C1',
      '(01)',
      '(99)XYZ',
      '01${validGtin}17',
      '~~~~',
      String.fromCharCodes(List.filled(300, 0x1D)),
    ]) {
      expect(() => parser.parse(raw), returnsNormally, reason: raw);
    }
  });
}
