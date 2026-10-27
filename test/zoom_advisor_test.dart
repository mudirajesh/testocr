import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/services/zoom_advisor.dart';
import 'package:gs1scan/utils/constants.dart';

void main() {
  const small = 0.1;
  const normal = 0.3;
  const large = 0.6;

  test('the first small detection advises moving closer', () {
    final advisor = ZoomAdvisor();
    expect(advisor.onDetection(small), ZoomAdvice.moveCloser);
    expect(advisor.isSmall, isTrue);
  });

  test('6 small detections advise zooming in, once', () {
    final advisor = ZoomAdvisor();
    final advice = [for (var i = 0; i < 9; i++) advisor.onDetection(small)];

    expect(advice[0], ZoomAdvice.moveCloser);
    expect(advice.sublist(1, kSmallBarcodeFramesBeforeZoom - 1), [
      for (var i = 1; i < kSmallBarcodeFramesBeforeZoom - 1; i++)
        ZoomAdvice.none,
    ]);
    expect(advice[kSmallBarcodeFramesBeforeZoom - 1], ZoomAdvice.zoomIn);
    expect(advice.where((a) => a == ZoomAdvice.zoomIn).length, 1);
    expect(advisor.zoomed, isTrue);
  });

  test('a barcode of normal size gives no advice', () {
    final advisor = ZoomAdvisor();
    for (var i = 0; i < 20; i++) {
      expect(advisor.onDetection(normal), ZoomAdvice.none);
    }
    expect(advisor.isSmall, isFalse);
  });

  test('the boundary: exactly the minimum width is not small', () {
    final advisor = ZoomAdvisor();
    expect(advisor.onDetection(kMinBarcodeWidthFraction), ZoomAdvice.none);
  });

  test('a large detection resets the small counter', () {
    final advisor = ZoomAdvisor();
    for (var i = 0; i < 5; i++) {
      advisor.onDetection(small);
    }
    expect(advisor.onDetection(normal), ZoomAdvice.none);
    expect(advisor.isSmall, isFalse);

    // The count starts over: 5 more small ones do not zoom yet.
    for (var i = 0; i < 5; i++) {
      expect(advisor.onDetection(small), isNot(ZoomAdvice.zoomIn));
    }
    expect(advisor.onDetection(small), ZoomAdvice.zoomIn);
  });

  test('a frame without a barcode breaks the run', () {
    final advisor = ZoomAdvisor();
    for (var i = 0; i < 5; i++) {
      advisor.onDetection(small);
    }
    advisor.onNoDetection();
    expect(advisor.isSmall, isFalse);
    expect(advisor.onDetection(small), ZoomAdvice.moveCloser);
  });

  test('zoom out after 5 large detections while zoomed', () {
    final advisor = ZoomAdvisor();
    for (var i = 0; i < kSmallBarcodeFramesBeforeZoom; i++) {
      advisor.onDetection(small);
    }
    expect(advisor.zoomed, isTrue);

    final advice = [for (var i = 0; i < 6; i++) advisor.onDetection(large)];
    expect(advice, [
      ZoomAdvice.none,
      ZoomAdvice.none,
      ZoomAdvice.none,
      ZoomAdvice.none,
      ZoomAdvice.zoomOut,
      ZoomAdvice.none,
    ]);
    expect(advisor.zoomed, isFalse);
  });

  test('a medium detection while zoomed resets the zoom-out run', () {
    final advisor = ZoomAdvisor();
    for (var i = 0; i < kSmallBarcodeFramesBeforeZoom; i++) {
      advisor.onDetection(small);
    }
    for (var i = 0; i < 4; i++) {
      advisor.onDetection(large);
    }
    advisor.onDetection(0.3); // not larger than 0.45
    for (var i = 0; i < 4; i++) {
      expect(advisor.onDetection(large), ZoomAdvice.none);
    }
    expect(advisor.onDetection(large), ZoomAdvice.zoomOut);
  });

  test('large detections without zoom never advise zooming out', () {
    final advisor = ZoomAdvisor();
    for (var i = 0; i < 20; i++) {
      expect(advisor.onDetection(large), ZoomAdvice.none);
    }
  });

  test('can zoom in again after zooming out', () {
    final advisor = ZoomAdvisor();
    for (var i = 0; i < kSmallBarcodeFramesBeforeZoom; i++) {
      advisor.onDetection(small);
    }
    for (var i = 0; i < 5; i++) {
      advisor.onDetection(large);
    }
    ZoomAdvice? last;
    for (var i = 0; i < kSmallBarcodeFramesBeforeZoom; i++) {
      last = advisor.onDetection(small);
    }
    expect(last, ZoomAdvice.zoomIn);
  });

  test('reset clears everything', () {
    final advisor = ZoomAdvisor();
    for (var i = 0; i < kSmallBarcodeFramesBeforeZoom; i++) {
      advisor.onDetection(small);
    }
    advisor.reset();

    expect(advisor.zoomed, isFalse);
    expect(advisor.isSmall, isFalse);
    expect(advisor.onDetection(small), ZoomAdvice.moveCloser);
  });

  test('never advises zooming in when the device cannot zoom', () {
    final advisor = ZoomAdvisor()..canZoom = false;
    final advice = [for (var i = 0; i < 20; i++) advisor.onDetection(small)];

    expect(advice.first, ZoomAdvice.moveCloser);
    expect(advice.skip(1).every((a) => a == ZoomAdvice.none), isTrue);
    expect(advisor.zoomed, isFalse);
  });
}
