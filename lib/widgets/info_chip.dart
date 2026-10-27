import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Small monospace chip, e.g. "STORED LOCALLY".
class InfoChip extends StatelessWidget {
  const InfoChip({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.infoTint,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.primaryDark),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppTextStyles.label.copyWith(
              fontSize: 10,
              letterSpacing: 1,
              color: AppColors.primaryDark,
            ),
          ),
        ],
      ),
    );
  }
}
