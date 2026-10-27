import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

const kReadinessTitle = 'Ready for GS1 & NDC verification';
const kReadinessBody =
    'Automatic format resolution handles 10/11-digit NDCs, 2D DataMatrix '
    'packs, and hospital unit-dose vials without manual switching.';

class ReadinessCard extends StatelessWidget {
  const ReadinessCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.infoTint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.15)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.verified_user_outlined,
            size: 24,
            color: AppColors.primaryDark,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  kReadinessTitle,
                  style: AppTextStyles.headline.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  kReadinessBody,
                  style: AppTextStyles.body.copyWith(
                    fontSize: 13,
                    height: 1.45,
                    color: AppColors.neutral,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
