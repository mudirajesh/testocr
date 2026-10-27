import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Corner-bracket scan frame with an animated scan line.
///
/// [lineAnimation] drives the line position from top (0) to bottom (1).
class ScanFrame extends StatelessWidget {
  const ScanFrame({super.key, required this.lineAnimation});

  final Animation<double> lineAnimation;

  static const double _lineInset = 14;
  static const double _lineThickness = 2;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final travel = constraints.maxHeight - _lineThickness;
        return Stack(
          children: [
            const Positioned.fill(
              child: CustomPaint(painter: _CornerBracketsPainter()),
            ),
            AnimatedBuilder(
              animation: lineAnimation,
              builder: (context, _) => Positioned(
                left: _lineInset,
                right: _lineInset,
                top: travel * lineAnimation.value,
                height: _lineThickness,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.secondary,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.secondary.withValues(alpha: 0.6),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CornerBracketsPainter extends CustomPainter {
  const _CornerBracketsPainter();

  static const double _arm = 28;
  static const double _stroke = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.secondary.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Inset by half the stroke so the caps are not clipped at the edges.
    const i = _stroke / 2;
    final l = i, t = i, r = size.width - i, b = size.height - i;

    final path = Path()
      ..moveTo(l, t + _arm)
      ..lineTo(l, t)
      ..lineTo(l + _arm, t)
      ..moveTo(r - _arm, t)
      ..lineTo(r, t)
      ..lineTo(r, t + _arm)
      ..moveTo(r, b - _arm)
      ..lineTo(r, b)
      ..lineTo(r - _arm, b)
      ..moveTo(l + _arm, b)
      ..lineTo(l, b)
      ..lineTo(l, b - _arm);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
