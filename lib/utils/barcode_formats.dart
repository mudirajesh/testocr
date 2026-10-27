import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

/// Formats that can carry a batch/lot number. Retail EAN-13/EAN-8 are
/// excluded so a product barcode is never chosen over the lot code.
const kMlKitScanFormats = <BarcodeFormat>[
  BarcodeFormat.dataMatrix,
  BarcodeFormat.code128,
  BarcodeFormat.code39,
  BarcodeFormat.code93,
  BarcodeFormat.itf,
  BarcodeFormat.pdf417,
  BarcodeFormat.codabar,
  BarcodeFormat.qrCode,
];

String? mlKitFormatName(BarcodeFormat format) {
  switch (format) {
    case BarcodeFormat.code128:
      return 'code128';
    case BarcodeFormat.dataMatrix:
      return 'dataMatrix';
    case BarcodeFormat.qrCode:
      return 'qrCode';
    case BarcodeFormat.code39:
      return 'code39';
    case BarcodeFormat.code93:
      return 'code93';
    case BarcodeFormat.itf:
      return 'itf';
    case BarcodeFormat.pdf417:
      return 'pdf417';
    case BarcodeFormat.codabar:
      return 'codabar';
    case BarcodeFormat.ean13:
      return 'ean13';
    case BarcodeFormat.ean8:
      return 'ean8';
    default:
      return null;
  }
}
