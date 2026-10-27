import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';

/// Large tappable card used for the primary home actions.
class ActionCard extends StatelessWidget {
  const ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.backgroundColor,
    required this.tileColor,
    required this.iconColor,
    required this.titleColor,
    required this.subtitleColor,
    this.borderColor,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color backgroundColor;
  final Color tileColor;
  final Color iconColor;
  final Color titleColor;
  final Color subtitleColor;
  final Color? borderColor;

  /// Optional widget shown at the top-right (e.g. an [InfoChip]).
  final Widget? trailing;

  static const double _radius = 20;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
        side: borderColor == null
            ? BorderSide.none
            : BorderSide(color: borderColor!),
      ),
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 160),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: tileColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, size: 28, color: iconColor),
                    ),
                    ?trailing,
                  ],
                ),
                const SizedBox(height: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.headline.copyWith(
                        fontSize: 22,
                        color: titleColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: AppTextStyles.body.copyWith(
                        fontSize: 13,
                        color: subtitleColor,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
