import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.value, required this.caption});

  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 88),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.tertiary),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: AppTextStyles.headline.copyWith(
              fontSize: 26,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            caption,
            style: AppTextStyles.body.copyWith(
              fontSize: 13,
              color: AppColors.neutral,
            ),
          ),
        ],
      ),
    );
  }
}
