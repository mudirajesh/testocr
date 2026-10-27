import 'package:flutter/material.dart';

import '../services/database_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Tells the user that the database file was unreadable and had to be reset.
/// Shown at most once: pressing OK clears the flag on [db]. It cannot be
/// dismissed any other way, so the notice is never missed.
Future<void> showDbCorruptionDialogIfNeeded(
  BuildContext context,
  DatabaseService db,
) async {
  if (!db.wasResetDueToCorruption) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(
          'Database reset',
          style: AppTextStyles.headline.copyWith(
            fontSize: 18,
            color: AppColors.textPrimary,
          ),
        ),
        content: Text(
          'The database was reset due to corruption. Previous records are '
          'lost.',
          style: AppTextStyles.body.copyWith(
            fontSize: 14,
            color: AppColors.neutral,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              db.acknowledgeCorruptionReset();
              Navigator.of(dialogContext).pop();
            },
            child: Text(
              'OK',
              style: AppTextStyles.body.copyWith(
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
