import 'package:flutter/material.dart';

import '../models/scan_record.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});

  final ScanStatus status;

  @override
  Widget build(BuildContext context) {
    final isPass = status == ScanStatus.pass;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: isPass ? AppColors.successTint : AppColors.dangerTint,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isPass ? 'PASS' : 'ALERT',
        style: AppTextStyles.label.copyWith(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: isPass ? AppColors.success : AppColors.danger,
        ),
      ),
    );
  }
}
