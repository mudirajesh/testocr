import '../utils/validators.dart';

/// One barcode seen in a camera frame. Pure Dart.
class DetectedBarcode {
  const DetectedBarcode({
    required this.rawValue,
    required this.format,
    required this.centerX,
    required this.centerY,
    this.widthFraction = 1.0,
  });

  final String rawValue;

  /// "code128", "dataMatrix", "qrCode", "code39", "itf", ...
  final String format;

  /// Barcode centre, normalized 0..1 in the upright (rotated) image.
  final double centerX;
  final double centerY;

  /// Bounding-box width divided by the upright image width, 0..1.
  final double widthFraction;

  @override
  String toString() => 'DetectedBarcode($format, $rawValue)';
}

/// When several barcodes are visible, only the one closest to the image
/// centre (0.5, 0.5) is processed. Null for an empty list.
DetectedBarcode? pickCentermost(List<DetectedBarcode> items) {
  DetectedBarcode? best;
  var bestDistance = double.infinity;
  for (final item in items) {
    final dx = item.centerX - 0.5;
    final dy = item.centerY - 0.5;
    final distance = dx * dx + dy * dy;
    if (distance < bestDistance) {
      best = item;
      bestDistance = distance;
    }
  }
  return best;
}

/// Prefers a barcode that carries a batch/lot number. Retail EAN/UPC and
/// URL payloads are ignored when a lot code is also in view.
DetectedBarcode? pickBatchBarcode(List<DetectedBarcode> items) {
  if (items.isEmpty) return null;
  final withBatch = items
      .where((item) => looksLikeBatchPayload(item.rawValue))
      .toList();
  if (withBatch.isNotEmpty) return pickCentermost(withBatch);
  final nonRetail = items
      .where((item) => item.format != 'ean13' && item.format != 'ean8')
      .toList();
  if (nonRetail.isNotEmpty) return pickCentermost(nonRetail);
  return pickCentermost(items);
}
