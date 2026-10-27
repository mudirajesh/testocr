import 'gs1_constants.dart';

/// Human-readable barcode format label for a detected format name
/// ("code128", "dataMatrix", ...). Decide from the parse whether a Code 128
/// was carrying GS1 AI data (labelled GS1-128) or anything else (Code 128).
String barcodeFormatLabel(String format, bool isGs1) {
  switch (format) {
    case 'code128':
      return isGs1 ? 'GS1-128' : 'Code 128';
    case 'dataMatrix':
      return 'DataMatrix';
    case 'qrCode':
      return 'QR';
    case 'code39':
      return 'Code 39';
    case 'code93':
      return 'Code 93';
    case 'itf':
      return 'ITF';
    case 'pdf417':
      return 'PDF417';
    case 'codabar':
      return 'Codabar';
    case 'ean13':
      return kFormatEan13;
    case 'ean8':
      return kFormatEan8;
    default:
      return format;
  }
}
