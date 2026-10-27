import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/scan_record.dart';
import '../providers/scanner_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/constants.dart';
import '../widgets/camera_preview_cover.dart';
import '../widgets/camera_problem_view.dart';
import '../widgets/overlay_pill.dart';
import '../widgets/scan_frame.dart';
import '../widgets/scan_result_sheet.dart';
import 'manual_entry_screen.dart';

/// Vertical positions (fraction of screen height) of the scan overlay.
const double kFrameTopFraction = 0.46;
const double kPillTopFraction = 0.36;

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _fade;
  late final AnimationController _scanLine;
  late final AnimationController _pulse;
  late final ScannerProvider _scanner;

  StreamSubscription<String>? _messageSub;
  ScannerStatus? _lastStatus;
  bool _presenting = false;

  // Mock fallback (kMockScanFallback): no camera, fixed 3-second scan.
  Timer? _mockTimer;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..forward();
    _scanLine = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0.55,
      upperBound: 1,
      value: 1,
    );

    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    WidgetsBinding.instance.addObserver(this);

    _scanner = context.read<ScannerProvider>();
    if (kMockScanFallback) {
      _startMockScan();
    } else {
      _scanner.addListener(_onScannerChanged);
      _messageSub = _scanner.messages.listen(_showMessage);
      // After the first frame: start() notifies, which must not happen
      // while the tree is still building.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scanner.start();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _mockTimer?.cancel();
    _messageSub?.cancel();
    if (!kMockScanFallback) {
      _scanner.removeListener(_onScannerChanged);
      unawaited(_scanner.stop()); // releases the camera
    }
    _fade.dispose();
    _scanLine.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kMockScanFallback) return;
    if (state == AppLifecycleState.paused) {
      _scanner.onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      _scanner.onAppResumed();
    }
  }

  // ---------------------------------------------------------- provider events

  void _onScannerChanged() {
    final status = _scanner.status;
    _syncAnimations(status);
    if (status == _lastStatus) return;
    _lastStatus = status;

    if (status == ScannerStatus.success ||
        status == ScannerStatus.lowConfidence ||
        status == ScannerStatus.needsReview) {
      _presentResult();
    }
  }

  /// The scan line runs only while scanning or processing; the pill pulses
  /// only while scanning.
  void _syncAnimations(ScannerStatus status) {
    final scanning = status == ScannerStatus.scanning;
    final active = scanning || status == ScannerStatus.processing;

    if (active && !_scanLine.isAnimating) {
      _scanLine.repeat(reverse: true);
    } else if (!active) {
      _scanLine.stop();
    }

    if (scanning && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!scanning) {
      _pulse
        ..stop()
        ..value = 1;
    }
  }

  /// Opens the right sheet for the current result, once per accepted result.
  Future<void> _presentResult() async {
    if (_presenting) return;
    final record = _scanner.result;
    if (record == null) return;
    _presenting = true;
    // The camera stays paused (and the "having trouble" timer quiet) while a
    // sheet is open, also across app backgrounding.
    _scanner.setSheetOpen(true);
    try {
      if (_scanner.status == ScannerStatus.success) {
        final action = await showScanResultSheet(
          context,
          record,
          mode: ScanSheetMode.success,
        );
        if (!mounted) return;
        if (action == ScanSheetAction.scanNext) {
          _scanner.rescan();
        } else {
          // Finished this scan -> return to Home instead of continuous loop.
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        }
        return;
      }

      // lowConfidence / needsReview: nothing is saved until the user says so.
      var saveFailed = _scanner.saveFailed;
      while (true) {
        final action = await showScanResultSheet(
          context,
          record,
          mode: ScanSheetMode.warning,
          issues: _scanner.issues,
          saveFailed: saveFailed,
        );
        if (!mounted) return;

        if (action != ScanSheetAction.saveAnyway) {
          _scanner.rescan(); // Rescan (the sheet cannot be dismissed)
          return;
        }
        final saved = await _scanner.saveCurrent();
        if (!mounted) return;
        if (saved) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(content: Text('Saved with warnings')),
            );
          _scanner.rescan();
          return;
        }
        saveFailed = true; // reopen with the failure banner
      }
    } finally {
      _presenting = false;
    }
  }

  // ---------------------------------------------------------- small actions

  void _showMessage(String message) {
    if (!mounted) return;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
          // Above the status pill and hint row at the bottom.
          margin: EdgeInsets.fromLTRB(16, 0, 16, bottomInset + 160),
        ),
      );
  }

  Future<void> _onFlash() async {
    if (kMockScanFallback) return;
    if (!_scanner.torchSupported) {
      _showMessage('Flash is not available on this device');
      return;
    }
    final ok = await _scanner.toggleTorch();
    if (!ok && mounted) _showMessage('Flash is not available on this device');
  }

  /// The camera is paused while manual entry covers it.
  Future<void> _openManualEntry() async {
    if (!kMockScanFallback) await _scanner.pauseForExternalScreen();
    if (!mounted) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const ManualEntryScreen()),
    );
    if (!mounted) return;
    if (!kMockScanFallback) await _scanner.resumeAfterExternalScreen();
    if (!mounted) return;
    if (saved == true) _showMessage('Manual entry saved');
  }

  /// Picks an image from the gallery to run barcode scan + fallback OCR.
  Future<void> _openImagePicker() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked != null && mounted) {
        _showMessage('Analyzing image...');
        await _scanner.processImportedImage(picked.path);
      }
    } catch (e) {
      debugPrint('Image picker error: $e');
      _showMessage('Failed to pick image');
    }
  }

  String _hintText(ScannerProvider s, ScannerStatus status) {
    final active =
        status == ScannerStatus.scanning || status == ScannerStatus.processing;
    if (active && s.lowLight) return 'Too dark · Turn on the torch';
    if (active && s.barcodeTooSmall && !s.isZoomed) {
      return 'Barcode is small · Move closer';
    }
    if (active && s.isZoomed) {
      return 'Zoom ${kAutoZoomLevel.toStringAsFixed(0)}x on · '
          'Move closer if it will not read';
    }
    return 'Hold steady · Good lighting · Move closer';
  }

  // ------------------------------------------------------------ mock fallback

  /// Old behaviour for devices without a camera: 3 seconds, then the mock
  /// result. Only used when kMockScanFallback is true.
  void _startMockScan() {
    _mockTimer?.cancel();
    _scanLine.repeat(reverse: true);
    _mockTimer = Timer(const Duration(seconds: 3), () async {
      if (!mounted) return;
      _scanLine.stop();
      // Mock values from the earlier design; never saved.
      final record = ScanRecord.create(
        rawBarcode: '(01)08901234567890(17)261231(10)BN2024X981',
        barcodeFormat: 'DataMatrix',
        batchNumber: 'BN2024X981',
        gtin: '08901234567890',
        expiryDate: '261231',
        confidenceScore: 1.0,
      );
      await showScanResultSheet(context, record, mode: ScanSheetMode.success);
      if (mounted) _startMockScan();
    });
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final scanner = context.watch<ScannerProvider>();
    final status = kMockScanFallback ? ScannerStatus.scanning : scanner.status;
    final size = MediaQuery.sizeOf(context);
    final frameWidth = size.width - 60;
    final frameHeight = frameWidth * 0.65;

    final pill = _pillFor(status);

    // The camera cannot be used: a full-screen explanation instead of the
    // scanner overlay.
    final problem = switch (status) {
      ScannerStatus.permissionDenied => CameraProblemKind.permission,
      ScannerStatus.noCamera => CameraProblemKind.noCamera,
      ScannerStatus.error => CameraProblemKind.error,
      _ => null,
    };
    if (problem != null) {
      return CameraProblemView(
        kind: problem,
        permanentlyDenied: scanner.permissionPermanentlyDenied,
        onPrimary: () {
          if (problem == CameraProblemKind.permission &&
              scanner.permissionPermanentlyDenied) {
            openAppSettings();
          } else {
            scanner.start();
          }
        },
        onEnterManually: _openManualEntry,
        onBack: () => Navigator.of(context).pop(),
      );
    }

    final active =
        status == ScannerStatus.scanning || status == ScannerStatus.processing;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: AppColors.mockCameraBottom,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (kMockScanFallback)
              const _MockCamera()
            else
              _CameraBackdrop(controller: scanner.cameraController),
            FadeTransition(
              opacity: _fade,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned(
                    top: size.height * kFrameTopFraction,
                    left: 30,
                    width: frameWidth,
                    height: frameHeight,
                    child: ScanFrame(lineAnimation: _scanLine),
                  ),
                  Positioned(
                    top: size.height * kPillTopFraction,
                    left: 16,
                    right: 16,
                    child: const Center(child: _InstructionPill()),
                  ),
                  if (active && scanner.lowLight)
                    Positioned(
                      top: size.height * kPillTopFraction - 52,
                      left: 16,
                      right: 16,
                      child: Center(child: _LowLightChip(onTap: _onFlash)),
                    ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: _TopControls(
                          flashOn: scanner.torchOn,
                          flashSupported: scanner.torchSupported,
                          onBack: () => Navigator.of(context).pop(),
                          onFlash: _onFlash,
                          onPickImage: _openImagePicker,
                        ),
                      ),
                    ),
                  ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: _BottomStatus(
                          label: pill?.label,
                          color: pill?.color ?? AppColors.primary,
                          hint: _hintText(scanner, status),
                          pulse: _pulse,
                          showTroubleCard:
                              scanner.showTroubleHint &&
                              status == ScannerStatus.scanning,
                          onDismissTrouble: scanner.dismissTroubleHint,
                          onManualEntry: _openManualEntry,
                          onCapture: () => scanner.captureManual(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  _PillStyle? _pillFor(ScannerStatus status) {
    switch (status) {
      case ScannerStatus.initializing:
        return const _PillStyle('Starting camera...', AppColors.primary);
      case ScannerStatus.scanning:
        return const _PillStyle('Scanning...', AppColors.primary);
      case ScannerStatus.processing:
        return const _PillStyle('Processing...', AppColors.primary);
      case ScannerStatus.success:
        return const _PillStyle('Scan Successful', AppColors.success);
      case ScannerStatus.lowConfidence:
        return const _PillStyle('Low confidence', AppColors.danger);
      case ScannerStatus.needsReview:
        return const _PillStyle('Check scan', AppColors.warning);
      case ScannerStatus.error:
      case ScannerStatus.noCamera:
      case ScannerStatus.permissionDenied:
        return null; // the camera problem view replaces the overlay
    }
  }
}

class _PillStyle {
  const _PillStyle(this.label, this.color);

  final String label;
  final Color color;
}

/// Live preview scaled to cover the screen, with the scrim on top. Falls back
/// to the dark gradient while the camera starts or is unavailable.
class _CameraBackdrop extends StatelessWidget {
  const _CameraBackdrop({required this.controller});

  final CameraController? controller;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.mockCameraTop, AppColors.mockCameraBottom],
            ),
          ),
        ),
        if (controller != null) CameraPreviewCover(controller: controller),
        const ColoredBox(color: AppColors.scrim),
      ],
    );
  }
}

class _MockCamera extends StatelessWidget {
  const _MockCamera();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/images/scan_mock_bg.png',
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.mockCameraTop, AppColors.mockCameraBottom],
              ),
            ),
          ),
        ),
        const ColoredBox(color: AppColors.scrim),
      ],
    );
  }
}

class _SquareButton extends StatelessWidget {
  const _SquareButton({
    required this.size,
    required this.icon,
    required this.iconSize,
    required this.onTap,
    required this.tooltip,
  });

  final double size;
  final IconData icon;
  final double iconSize;
  final VoidCallback onTap;
  final String tooltip;

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
          child: Tooltip(
            message: tooltip,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, size: iconSize, color: AppColors.primary),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopControls extends StatelessWidget {
  const _TopControls({
    required this.flashOn,
    required this.flashSupported,
    required this.onBack,
    required this.onFlash,
    required this.onPickImage,
  });

  final bool flashOn;

  /// False on devices without a flash: the button is dimmed (and explains
  /// itself when tapped).
  final bool flashSupported;
  final VoidCallback onBack;
  final VoidCallback onFlash;
  final VoidCallback onPickImage;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _SquareButton(
          size: 44,
          icon: Icons.chevron_left,
          iconSize: 28,
          onTap: onBack,
          tooltip: 'Back',
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SquareButton(
              size: 44,
              icon: Icons.photo_library_outlined,
              iconSize: 22,
              onTap: onPickImage,
              tooltip: 'Import image / OCR',
            ),
            const SizedBox(width: 10),
            Opacity(
              opacity: flashSupported ? 1 : 0.4,
              child: _SquareButton(
                size: 44,
                icon: flashOn
                    ? Icons.flash_off_outlined
                    : Icons.flash_on_outlined,
                iconSize: 22,
                onTap: onFlash,
                tooltip: 'Flash',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// "Low light" warning near the instruction pill; tapping it toggles the
/// torch.
class _LowLightChip extends StatelessWidget {
  const _LowLightChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.warningTint,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.light_mode_outlined,
                size: 18,
                color: AppColors.warning,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Low light. Tap the flash button.',
                  style: AppTextStyles.body.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.warning,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstructionPill extends StatelessWidget {
  const _InstructionPill();

  @override
  Widget build(BuildContext context) {
    return OverlayPill(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.qr_code_scanner, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Align barcode within the frame',
              style: AppTextStyles.headline.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomStatus extends StatelessWidget {
  const _BottomStatus({
    required this.label,
    required this.color,
    required this.hint,
    required this.pulse,
    required this.showTroubleCard,
    required this.onDismissTrouble,
    required this.onManualEntry,
    required this.onCapture,
  });

  /// Null hides the status pill.
  final String? label;
  final Color color;
  final String hint;
  final Animation<double> pulse;
  final bool showTroubleCard;
  final VoidCallback onDismissTrouble;
  final VoidCallback onManualEntry;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTroubleCard) ...[
          _TroubleCard(onManualEntry: onManualEntry, onClose: onDismissTrouble),
          const SizedBox(height: 12),
        ],
        if (label != null) ...[
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 160, minHeight: 52),
            child: OverlayPill(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Center(
                widthFactor: 1,
                child: FadeTransition(
                  opacity: pulse,
                  child: Text(
                    label!,
                    style: AppTextStyles.headline.copyWith(
                      fontSize: 16,
                      color: color,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            Expanded(
              child: OverlayPill(
                child: Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.label.copyWith(
                    fontSize: 11,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _SquareButton(
              size: 48,
              icon: Icons.camera_alt_outlined,
              iconSize: 22,
              onTap: onCapture,
              tooltip: 'Capture photo',
            ),
            const SizedBox(width: 8),
            _SquareButton(
              size: 48,
              icon: Icons.keyboard_outlined,
              iconSize: 22,
              onTap: onManualEntry,
              tooltip: 'Manual entry',
            ),
          ],
        ),
      ],
    );
  }
}

/// Shown after 15 seconds without a barcode in view.
class _TroubleCard extends StatelessWidget {
  const _TroubleCard({required this.onManualEntry, required this.onClose});

  final VoidCallback onManualEntry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: OverlayPill.shadows,
      ),
      child: Material(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Having trouble?',
                      style: AppTextStyles.headline.copyWith(
                        fontSize: 15,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.close,
                      size: 20,
                      color: AppColors.neutral,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  'Try moving closer, improving lighting, or holding the '
                  'device steady.',
                  style: AppTextStyles.body.copyWith(
                    fontSize: 13,
                    color: AppColors.neutral,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Material(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onManualEntry,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Center(
                        child: Text(
                          'Enter batch manually',
                          style: AppTextStyles.headline.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.surfaceWhite,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
