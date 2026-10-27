import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// White rounded container with a soft shadow, used over the camera view.
class OverlayPill extends StatelessWidget {
  const OverlayPill({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.radius = 14,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;

  /// Shared soft shadow for all white overlay elements.
  static List<BoxShadow> get shadows => [
    BoxShadow(
      color: AppColors.shadow.withValues(alpha: 0.15),
      blurRadius: 12,
      offset: const Offset(0, 4),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: shadows,
      ),
      child: Material(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(radius),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
