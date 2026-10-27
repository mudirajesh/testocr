import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/models/scan_record.dart';

ScanRecord _record({String? expiry, double? confidence}) => ScanRecord(
  id: 'id-1',
  rawBarcode: '(01)08901234567890',
  barcodeFormat: 'GS1-128',
  expiryDate: expiry,
  scanTimestamp: DateTime(2026, 9, 29, 14, 32),
  confidenceScore: confidence,
);

void main() {
  group('toMap / fromMap', () {
    test('round trips all fields', () {
      final r = ScanRecord(
        id: 'abc',
        rawBarcode: '(01)08901234567890(17)261231(10)B1(21)S1',
        barcodeFormat: 'DataMatrix',
        batchNumber: 'B1',
        gtin: '08901234567890',
        expiryDate: '261231',
        serialNumber: 'S1',
        scanTimestamp: DateTime(2026, 9, 29, 14, 32, 5, 123),
        confidenceScore: 0.8,
        isValid: false,
      );
      final back = ScanRecord.fromMap(r.toMap());
      expect(back, r);
      expect(back.rawBarcode, r.rawBarcode);
      expect(back.barcodeFormat, r.barcodeFormat);
      expect(back.batchNumber, 'B1');
      expect(back.gtin, '08901234567890');
      expect(back.expiryDate, '261231');
      expect(back.serialNumber, 'S1');
      expect(back.scanTimestamp, r.scanTimestamp);
      expect(back.confidenceScore, 0.8);
      expect(back.isValid, false);
      expect(r.toMap()['is_valid'], 0);
    });

    test('round trips null fields', () {
      final back = ScanRecord.fromMap(_record().toMap());
      expect(back.batchNumber, isNull);
      expect(back.gtin, isNull);
      expect(back.expiryDate, isNull);
      expect(back.serialNumber, isNull);
      expect(back.confidenceScore, isNull);
      expect(back.isValid, true);
    });
  });

  group('create / status / equality', () {
    test('create generates a unique id and a timestamp', () {
      final a = ScanRecord.create(rawBarcode: 'x', barcodeFormat: 'QR');
      final b = ScanRecord.create(rawBarcode: 'x', barcodeFormat: 'QR');
      expect(a.id, isNot(b.id));
      expect(a.id.length, 36);
      expect(
        DateTime.now().difference(a.scanTimestamp).inSeconds.abs() < 5,
        true,
      );
    });

    test('status follows isValid', () {
      expect(_record().status, ScanStatus.pass);
      expect(_record().copyWith(isValid: false).status, ScanStatus.alert);
    });

    test('equality is based on id', () {
      expect(_record(), _record(expiry: '261231'));
      expect(_record().hashCode, _record().hashCode);
      expect(_record(), isNot(_record().copyWith(id: 'other')));
    });
  });

  group('expiryDisplay', () {
    test('formats YYMMDD', () {
      expect(_record(expiry: '261231').expiryDisplay, '31/12/2026');
    });
    test('day 00 means last day of month', () {
      expect(_record(expiry: '261200').expiryDisplay, '31/12/2026');
      expect(_record(expiry: '270200').expiryDisplay, '28/02/2027');
      expect(_record(expiry: '280200').expiryDisplay, '29/02/2028');
    });
    test('invalid or missing gives null', () {
      expect(_record().expiryDisplay, isNull);
      expect(_record(expiry: '').expiryDisplay, isNull);
      expect(_record(expiry: '26123').expiryDisplay, isNull);
      expect(_record(expiry: 'abcdef').expiryDisplay, isNull);
      expect(_record(expiry: '261301').expiryDisplay, isNull);
      expect(_record(expiry: '260231').expiryDisplay, isNull);
    });
  });

  group('confidencePercent', () {
    test('formats the score', () {
      expect(_record(confidence: 0.8).confidencePercent, '80%');
      expect(_record(confidence: 1.0).confidencePercent, '100%');
      expect(_record(confidence: 0.256).confidencePercent, '26%');
    });
    test('null without a score', () {
      expect(_record().confidencePercent, isNull);
    });
  });
}
