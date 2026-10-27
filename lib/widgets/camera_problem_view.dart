import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import 'overlay_pill.dart';

enum CameraProblemKind { permission, noCamera, error }

/// Full-screen state for the Scan screen when the camera cannot be used.
/// It never shows raw exception text.
class CameraProblemView extends StatelessWidget {
  const CameraProblemView({
    super.key,
    required this.kind,
    this.permanentlyDenied = false,
    required this.onPrimary,
    required this.onEnterManually,
    required this.onBack,
  });

  final CameraProblemKind kind;

  /// Permission variant only: the system will not ask again, so the primary
  /// button opens the app settings instead of asking.
  final bool permanentlyDenied;

  /// The main action: ask again / open settings / try again. Unused for the
  /// no-camera variant, whose main action is manual entry.
  final VoidCallback onPrimary;
  final VoidCallback onEnterManually;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final content = _content();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned(top: 12, left: 16, child: _BackButton(onTap: onBack)),
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(32, 72, 32, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          color: content.tint,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          content.icon,
                          size: 40,
                          color: content.iconColor,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        content.title,
                        textAlign: TextAlign.center,
                        style: AppTextStyles.headline.copyWith(
                          fontSize: 22,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: Text(
                          content.body,
                          textAlign: TextAlign.center,
                          style: AppTextStyles.body.copyWith(
                            fontSize: 14,
                            height: 1.5,
                            color: AppColors.neutral,
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      _PrimaryButton(
                        label: content.primaryLabel,
                        onTap: content.primaryIsManual
                            ? onEnterManually
                            : onPrimary,
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: content.secondaryIsBack
                            ? onBack
                            : onEnterManually,
                        child: Text(
                          content.secondaryLabel,
                          style: AppTextStyles.body.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _ProblemContent _content() {
    switch (kind) {
      case CameraProblemKind.permission:
        return _ProblemContent(
          icon: Icons.camera_alt_outlined,
          iconColor: AppColors.primary,
          tint: AppColors.primaryTint,
          title: 'Camera permission needed',
          body:
              'GS1 Scan needs the camera to read pharmaceutical barcodes. '
              'Images never leave your device.',
          primaryLabel: permanentlyDenied ? 'Open Settings' : 'Allow camera',
          primaryIsManual: false,
          secondaryLabel: 'Enter batch manually',
          secondaryIsBack: false,
        );
      case CameraProblemKind.noCamera:
        return const _ProblemContent(
          icon: Icons.no_photography_outlined,
          iconColor: AppColors.primary,
          tint: AppColors.primaryTint,
          title: 'No camera found',
          body:
              'This device has no usable camera. You can still enter batch '
              'numbers manually and browse your scan history.',
          primaryLabel: 'Enter batch manually',
          primaryIsManual: true,
          secondaryLabel: 'Back',
          secondaryIsBack: true,
        );
      case CameraProblemKind.error:
        return const _ProblemContent(
          icon: Icons.error_outline,
          iconColor: AppColors.danger,
          tint: AppColors.dangerTint,
          title: 'Camera problem',
          body:
              'Something went wrong while using the camera. Please try '
              'again.',
          primaryLabel: 'Try again',
          primaryIsManual: false,
          secondaryLabel: 'Back',
          secondaryIsBack: true,
        );
    }
  }
}

class _ProblemContent {
  const _ProblemContent({
    required this.icon,
    required this.iconColor,
    required this.tint,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.primaryIsManual,
    required this.secondaryLabel,
    required this.secondaryIsBack,
  });

  final IconData icon;
  final Color iconColor;
  final Color tint;
  final String title;
  final String body;
  final String primaryLabel;
  final bool primaryIsManual;
  final String secondaryLabel;
  final bool secondaryIsBack;
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: OverlayPill.shadows,
      ),
      child: Material(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: const Tooltip(
            message: 'Back',
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                Icons.chevron_left,
                size: 28,
                color: AppColors.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52, minWidth: 220),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: AppTextStyles.headline.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.surfaceWhite,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
