import '../utils/constants.dart';

enum ZoomAdvice { none, moveCloser, zoomIn, zoomOut }

/// Decides when a small barcode should trigger auto-zoom. Pure Dart.
///
/// A detection narrower than [smallFraction] of the frame is "small". The
/// first small detection advises moving closer; after
/// [framesBeforeZoom] consecutive small ones (while not zoomed) it advises
/// zooming in, once. While zoomed, [framesBeforeZoomOut] consecutive
/// detections wider than [largeFraction] advise zooming back out, once.
class ZoomAdvisor {
  ZoomAdvisor({
    this.smallFraction = kMinBarcodeWidthFraction,
    this.largeFraction = 0.45,
    this.framesBeforeZoom = kSmallBarcodeFramesBeforeZoom,
    this.framesBeforeZoomOut = 5,
  });

  final double smallFraction;
  final double largeFraction;
  final int framesBeforeZoom;
  final int framesBeforeZoomOut;

  /// Set false on devices that cannot zoom: zoomIn is never advised, so the
  /// advisor and the camera cannot disagree about the zoom state.
  bool canZoom = true;

  int _smallStreak = 0;
  int _largeStreak = 0;
  bool _zoomed = false;

  /// The latest detection was small.
  bool get isSmall => _smallStreak > 0;

  bool get zoomed => _zoomed;

  ZoomAdvice onDetection(double widthFraction) {
    if (widthFraction < smallFraction) {
      _largeStreak = 0;
      _smallStreak++;
      if (canZoom && !_zoomed && _smallStreak >= framesBeforeZoom) {
        _zoomed = true;
        return ZoomAdvice.zoomIn;
      }
      return _smallStreak == 1 ? ZoomAdvice.moveCloser : ZoomAdvice.none;
    }

    // A large detection clears the small counter.
    _smallStreak = 0;
    if (_zoomed && widthFraction > largeFraction) {
      _largeStreak++;
      if (_largeStreak >= framesBeforeZoomOut) {
        _zoomed = false;
        _largeStreak = 0;
        return ZoomAdvice.zoomOut;
      }
    } else {
      _largeStreak = 0;
    }
    return ZoomAdvice.none;
  }

  /// A frame without a barcode breaks the "consecutive" runs.
  void onNoDetection() {
    _smallStreak = 0;
    _largeStreak = 0;
  }

  void reset() {
    _smallStreak = 0;
    _largeStreak = 0;
    _zoomed = false;
  }
}
