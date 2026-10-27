import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/utils/luminance.dart';

void main() {
  test('an all-black frame is 0', () {
    final bytes = Uint8List(64 * 48);
    expect(meanLuminance(bytes, 64, 48, 64), 0);
  });

  test('an all-white frame is 255', () {
    final bytes = Uint8List(64 * 48)..fillRange(0, 64 * 48, 255);
    expect(meanLuminance(bytes, 64, 48, 64), 255);
  });

  test('mixed known values are averaged', () {
    // 16x16 frame, sampled every 8 px: (0,0) (8,0) (0,8) (8,8).
    final bytes = Uint8List(16 * 16);
    bytes[0] = 10;
    bytes[8] = 20;
    bytes[8 * 16] = 30;
    bytes[8 * 16 + 8] = 40;
    expect(meanLuminance(bytes, 16, 16, 16), 25);
  });

  test('half bright, half dark gives the midpoint', () {
    final bytes = Uint8List(32 * 32);
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 32; x++) {
        bytes[y * 32 + x] = x < 16 ? 200 : 0;
      }
    }
    expect(meanLuminance(bytes, 32, 32, 32, step: 4), closeTo(100, 0.001));
  });

  test('row stride padding is never read as pixels', () {
    // 10 pixels per row, 16 bytes per row; the 6 padding bytes are 255.
    const width = 10;
    const height = 6;
    const stride = 16;
    final bytes = Uint8List(stride * height);
    for (var y = 0; y < height; y++) {
      for (var x = width; x < stride; x++) {
        bytes[y * stride + x] = 255;
      }
    }
    expect(meanLuminance(bytes, width, height, stride, step: 1), 0);
  });

  test('empty or degenerate input is 0', () {
    expect(meanLuminance(Uint8List(0), 64, 48, 64), 0);
    expect(meanLuminance(Uint8List(100), 0, 10, 10), 0);
    expect(meanLuminance(Uint8List(100), 10, 0, 10), 0);
    expect(meanLuminance(Uint8List(100), 10, 10, 10, step: 0), 0);
  });

  test('a buffer shorter than the frame does not throw', () {
    final bytes = Uint8List(20)..fillRange(0, 20, 100);
    expect(meanLuminance(bytes, 64, 48, 64), 100);
  });

  test('a step larger than the frame samples the top-left pixel', () {
    final bytes = Uint8List(16)..[0] = 77;
    expect(meanLuminance(bytes, 4, 4, 4, step: 100), 77);
  });
}
