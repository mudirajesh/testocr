import 'dart:typed_data';

/// Mean brightness (0..255) of a camera frame, from its Y (luma) plane.
///
/// Samples every [step] pixels in x and y, so it is cheap enough to run on
/// every frame. [rowStride] is the number of bytes per row, which can be
/// larger than [width]; the padding is never read as pixels. Returns 0 for
/// empty input.
double meanLuminance(
  Uint8List yPlane,
  int width,
  int height,
  int rowStride, {
  int step = 8,
}) {
  if (yPlane.isEmpty || width <= 0 || height <= 0 || step <= 0) return 0;

  var sum = 0;
  var count = 0;
  for (var y = 0; y < height; y += step) {
    final rowStart = y * rowStride;
    for (var x = 0; x < width; x += step) {
      final index = rowStart + x;
      if (index >= yPlane.length) continue;
      sum += yPlane[index];
      count++;
    }
  }
  return count == 0 ? 0 : sum / count;
}
