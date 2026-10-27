import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/utils/validators.dart';

void main() {
  group('isValidGtinCheckDigit', () {
    test('accepts a correct check digit', () {
      expect(isValidGtinCheckDigit('08901234567890'), isTrue);
      expect(isValidGtinCheckDigit('00000000000000'), isTrue);
    });

    test('rejects a wrong check digit', () {
      expect(isValidGtinCheckDigit('08901234567891'), isFalse);
      expect(isValidGtinCheckDigit('08901234567899'), isFalse);
    });

    test('rejects anything that is not 14 digits', () {
      expect(isValidGtinCheckDigit(''), isFalse);
      expect(isValidGtinCheckDigit('8901234567890'), isFalse);
      expect(isValidGtinCheckDigit('089012345678900'), isFalse);
      expect(isValidGtinCheckDigit('0890123456789O'), isFalse);
      expect(isValidGtinCheckDigit('0890 1234 5678 90'), isFalse);
    });
  });

  group('isValidGs1Date', () {
    test('accepts real dates', () {
      expect(isValidGs1Date('261231'), isTrue);
      expect(isValidGs1Date('260101'), isTrue);
      expect(isValidGs1Date('270228'), isTrue);
    });

    test('day 00 means end of month', () {
      expect(isValidGs1Date('261200'), isTrue);
      expect(isValidGs1Date('270200'), isTrue);
      expect(isValidGs1Date('280200'), isTrue);
    });

    test('handles leap years', () {
      expect(isValidGs1Date('280229'), isTrue); // 2028 is a leap year
      expect(isValidGs1Date('270229'), isFalse); // 2027 is not
      expect(isValidGs1Date('000229'), isTrue); // 2000 is a leap year
    });

    test('rejects impossible months and days', () {
      expect(isValidGs1Date('261301'), isFalse);
      expect(isValidGs1Date('260001'), isFalse);
      expect(isValidGs1Date('261232'), isFalse);
      expect(isValidGs1Date('260431'), isFalse);
    });

    test('rejects malformed input', () {
      expect(isValidGs1Date(''), isFalse);
      expect(isValidGs1Date('26123'), isFalse);
      expect(isValidGs1Date('2612311'), isFalse);
      expect(isValidGs1Date('2612O1'), isFalse);
    });
  });

  group('isValidBatch / isValidSerial', () {
    test('accept 1 to 20 characters', () {
      expect(isValidBatch('A'), isTrue);
      expect(isValidBatch('A' * 20), isTrue);
      expect(isValidSerial('A'), isTrue);
      expect(isValidSerial('A' * 20), isTrue);
    });

    test('reject empty or over-long values', () {
      expect(isValidBatch(''), isFalse);
      expect(isValidBatch('A' * 21), isFalse);
      expect(isValidSerial(''), isFalse);
      expect(isValidSerial('A' * 21), isFalse);
    });
  });

  group('batchCharWarning', () {
    test('is null for letters, digits, dot and dash', () {
      expect(batchCharWarning('LOT-2024.A1'), isNull);
      expect(batchCharWarning('BN2024X981'), isNull);
      expect(batchCharWarning(''), isNull);
    });

    test('warns about other characters without rejecting them', () {
      expect(batchCharWarning('LOT/2024'), isNotNull);
      expect(batchCharWarning('LOT_2024'), isNotNull);
      expect(batchCharWarning('LOT 2024'), isNotNull);
    });
  });

  group('isDigitsOnly / normalizeWhitespaceCommon', () {
    test('isDigitsOnly', () {
      expect(isDigitsOnly('0123'), isTrue);
      expect(isDigitsOnly(''), isFalse);
      expect(isDigitsOnly('01 23'), isFalse);
      expect(isDigitsOnly('01O3'), isFalse);
    });

    test('normalizeWhitespaceCommon trims only', () {
      expect(normalizeWhitespaceCommon('  AB  '), 'AB');
      expect(normalizeWhitespaceCommon('A B'), 'A B');
    });
  });
}
