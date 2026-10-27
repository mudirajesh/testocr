import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Barcode-in-brackets illustration drawn in code. The dashed scan line
/// gently pulses between 60% and 100% opacity.
class EmptyScanIllustration extends StatefulWidget {
  const EmptyScanIllustration({super.key, this.size = 100});

  final double size;

  @override
  State<EmptyScanIllustration> createState() => _EmptyScanIllustrationState();
}

class _EmptyScanIllustrationState extends State<EmptyScanIllustration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(painter: _IllustrationPainter(_pulse)),
    );
  }
}

class _IllustrationPainter extends CustomPainter {
  _IllustrationPainter(this.pulse) : super(repaint: pulse);

  final Animation<double> pulse;

  // Bar widths (2-6px) and gaps at a 100px reference size.
  static const _barWidths = [3.0, 2.0, 5.0, 2.0, 6.0, 3.0, 2.0, 5.0, 3.0];
  static const _barGaps = [4.0, 3.0, 4.0, 3.0, 4.0, 3.0, 4.0, 3.0];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final scale = w / 100;

    _paintBrackets(canvas, size);
    _paintBars(canvas, size, scale);
    _paintDashedLine(canvas, size);
  }

  void _paintBrackets(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    const i = 1.5; // half stroke, keeps caps inside the bounds
    const r = 8.0;
    final arm = size.width * 0.22;
    final right = size.width - i;
    final bottom = size.height - i;
    const radius = Radius.circular(r);

    final path = Path()
      // top-left
      ..moveTo(i, i + arm)
      ..lineTo(i, i + r)
      ..arcToPoint(const Offset(i + r, i), radius: radius)
      ..lineTo(i + arm, i)
      // top-right
      ..moveTo(right - arm, i)
      ..lineTo(right - r, i)
      ..arcToPoint(Offset(right, i + r), radius: radius)
      ..lineTo(right, i + arm)
      // bottom-right
      ..moveTo(right, bottom - arm)
      ..lineTo(right, bottom - r)
      ..arcToPoint(Offset(right - r, bottom), radius: radius)
      ..lineTo(right - arm, bottom)
      // bottom-left
      ..moveTo(i + arm, bottom)
      ..lineTo(i + r, bottom)
      ..arcToPoint(Offset(i, bottom - r), radius: radius)
      ..lineTo(i, bottom - arm);
    canvas.drawPath(path, paint);
  }

  void _paintBars(Canvas canvas, Size size, double scale) {
    final paint = Paint()..color = AppColors.primary.withValues(alpha: 0.45);
    final totalWidth =
        (_barWidths.reduce((a, b) => a + b) +
            _barGaps.reduce((a, b) => a + b)) *
        scale;
    final barHeight = size.height * 0.6;
    final top = (size.height - barHeight) / 2;

    var x = (size.width - totalWidth) / 2;
    for (var n = 0; n < _barWidths.length; n++) {
      final bw = _barWidths[n] * scale;
      canvas.drawRect(Rect.fromLTWH(x, top, bw, barHeight), paint);
      x += bw + (n < _barGaps.length ? _barGaps[n] * scale : 0);
    }
  }

  void _paintDashedLine(Canvas canvas, Size size) {
    final opacity = 0.6 + 0.4 * Curves.easeInOut.transform(pulse.value);
    final paint = Paint()
      ..color = AppColors.secondary.withValues(alpha: opacity)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.butt;

    const dash = 4.0;
    const gap = 3.0;
    final inset = size.width * 0.12;
    final y = size.height / 2;
    var x = inset;
    while (x < size.width - inset) {
      final end = (x + dash).clamp(0.0, size.width - inset);
      canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _IllustrationPainter oldDelegate) =>
      oldDelegate.pulse != pulse;
}
