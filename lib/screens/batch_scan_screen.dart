import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/batch_scan_item.dart';
import '../providers/batch_scan_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/constants.dart';
import '../widgets/camera_preview_cover.dart';
import '../widgets/camera_problem_view.dart';
import '../widgets/overlay_pill.dart';
import '../widgets/scan_frame.dart';
import 'batch_summary_screen.dart';
import 'manual_entry_screen.dart';

/// Vertical positions (fraction of screen height) of the scan overlay,
/// matching the single-scan screen.
const double _frameTopFraction = 0.46;
const double _pillTopFraction = 0.36;

/// Continuous multi-scan mode: reads barcodes one after another, auto-saves
/// every valid GS1 scan and finishes with a session summary.
class BatchScanScreen extends StatefulWidget {
  const BatchScanScreen({super.key});

  @override
  State<BatchScanScreen> createState() => _BatchScanScreenState();
}

class _BatchScanScreenState extends State<BatchScanScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _fade;
  late final AnimationController _scanLine;
  late final AnimationController _pulse;
  late final BatchScanProvider _batch;

  StreamSubscription<String>? _messageSub;
  bool _finishing = false;

  // Mock fallback (kMockScanFallback): no camera, a mock scan every 3 seconds.
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

    _batch = context.read<BatchScanProvider>();
    if (kMockScanFallback) {
      _startMockScan();
    } else {
      _batch.addListener(_syncAnimations);
      _messageSub = _batch.messages.listen(_showMessage);
      // After the first frame: start() notifies, which must not happen
      // while the tree is still building.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _batch.start();
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
      _batch.removeListener(_syncAnimations);
      unawaited(_batch.stop()); // releases the camera
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
      _batch.onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      _batch.onAppResumed();
    }
  }

  void _syncAnimations() {
    final scanning = _batch.status == BatchScanStatus.scanning;
    if (scanning && !_scanLine.isAnimating) {
      _scanLine.repeat(reverse: true);
    } else if (!scanning) {
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

  // ------------------------------------------------------------ small actions

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
          // Above the status pill and buttons at the bottom.
          margin: EdgeInsets.fromLTRB(16, 0, 16, bottomInset + 200),
        ),
      );
  }

  Future<void> _onFlash() async {
    if (kMockScanFallback) return;
    if (!_batch.torchSupported) {
      _showMessage('Flash is not available on this device');
      return;
    }
    final ok = await _batch.toggleTorch();
    if (!ok && mounted) _showMessage('Flash is not available on this device');
  }

  /// The session list opened; the camera is paused while it covers the screen.
  Future<void> _showSessionSheet() async {
    if (kMockScanFallback) return;
    await _batch.pauseForExternalScreen();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: AppColors.shadow.withValues(alpha: 0.4),
      useSafeArea: true,
      builder: (_) => const _SessionSheet(),
    );
    if (mounted && !kMockScanFallback) {
      await _batch.resumeAfterExternalScreen();
    }
  }

  /// The camera is paused while manual entry covers it.
  Future<void> _openManualEntry() async {
    if (!kMockScanFallback) await _batch.pauseForExternalScreen();
    if (!mounted) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const ManualEntryScreen()),
    );
    if (!mounted) return;
    if (!kMockScanFallback) await _batch.resumeAfterExternalScreen();
    if (!mounted) return;
    if (saved == true) _showMessage('Manual entry saved');
  }

  /// Stops the camera and opens the summary. The records are already saved;
  /// skipped ones cannot be fixed any more here.
  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    _mockTimer?.cancel();
    final items = _batch.items;
    if (!kMockScanFallback) await _batch.stop();
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => BatchSummaryScreen(items: items)),
    );
  }

  /// Back while a session has items: the user may not have meant to stop.
  Future<bool> _confirmBack() async {
    if (_batch.isEmpty) return true;
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End this batch session?'),
        content: const Text(
          'Saved scans stay in your history. The session summary would be '
          'closed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep scanning'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('End session'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  // ------------------------------------------------------------ mock fallback

  void _startMockScan() {
    _mockTimer?.cancel();
    _scanLine.repeat(reverse: true);
    final status = _batch.status;
    if (status == BatchScanStatus.initializing ||
        status == BatchScanStatus.error) {
      // The mock path has no camera; a fresh provider starts straight away.
      _batch.start();
    }
    _mockTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      _batch.mockScanOnce();
    });
  }

  String _hintText(BatchScanProvider s) {
    if (s.lowLight) return 'Too dark · Turn on the torch';
    if (s.barcodeTooSmall && !s.isZoomed) {
      return 'Barcode is small · Move closer';
    }
    if (s.isZoomed) {
      return 'Zoom ${kAutoZoomLevel.toStringAsFixed(0)}x on · '
          'Move closer if it will not read';
    }
    return 'Hold steady · Good lighting · Move closer';
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final batch = context.watch<BatchScanProvider>();
    final status = kMockScanFallback ? BatchScanStatus.scanning : batch.status;
    final size = MediaQuery.sizeOf(context);
    final frameWidth = size.width - 60;
    final frameHeight = frameWidth * 0.65;

    // The camera cannot be used: a full-screen explanation instead of the
    // scanner overlay.
    final problem = switch (status) {
      BatchScanStatus.permissionDenied => CameraProblemKind.permission,
      BatchScanStatus.noCamera => CameraProblemKind.noCamera,
      BatchScanStatus.error => CameraProblemKind.error,
      _ => null,
    };
    if (problem != null) {
      return CameraProblemView(
        kind: problem,
        permanentlyDenied: batch.permissionPermanentlyDenied,
        onPrimary: () {
          if (problem == CameraProblemKind.permission &&
              batch.permissionPermanentlyDenied) {
            openAppSettings();
          } else {
            batch.start();
          }
        },
        onEnterManually: _openManualEntry,
        onBack: () => Navigator.of(context).pop(),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: PopScope(
        canPop: kMockScanFallback || batch.isEmpty,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final confirmed = await _confirmBack();
          if (didPop || confirmed == false) return;
          if (mounted) Navigator.of(this.context).pop();
        },
        child: Scaffold(
          backgroundColor: AppColors.mockCameraBottom,
          body: Stack(
            fit: StackFit.expand,
            children: [
              _CameraBackdrop(controller: batch.cameraController),
              FadeTransition(
                opacity: _fade,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      top: size.height * _frameTopFraction,
                      left: 30,
                      width: frameWidth,
                      height: frameHeight,
                      child: ScanFrame(lineAnimation: _scanLine),
                    ),
                    Positioned(
                      top: size.height * _pillTopFraction,
                      left: 16,
                      right: 16,
                      child: const Center(child: _InstructionPill()),
                    ),
                    if (status == BatchScanStatus.scanning && batch.lowLight)
                      Positioned(
                        top: size.height * _pillTopFraction - 52,
                        left: 16,
                        right: 16,
                        child: Center(child: _LowLightChip(onTap: _onFlash)),
                      ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: _TopControls(
                          batch: batch,
                          onBack: () async {
                            final confirmed = await _confirmBack();
                            if (confirmed && mounted) {
                              Navigator.of(this.context).pop();
                            }
                          },
                          onFlash: _onFlash,
                          onShowSession: _showSessionSheet,
                        ),
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: _BottomControls(
                            batch: batch,
                            pulse: _pulse,
                            hint: _hintText(batch),
                            onManualEntry: _openManualEntry,
                            onShowSession: _showSessionSheet,
                            onFinish: _finish,
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
      ),
    );
  }
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
    required this.batch,
    required this.onBack,
    required this.onFlash,
    required this.onShowSession,
  });

  final BatchScanProvider batch;
  final VoidCallback onBack;
  final VoidCallback onFlash;
  final VoidCallback onShowSession;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _SquareButton(
          size: 44,
          icon: Icons.chevron_left,
          iconSize: 28,
          onTap: onBack,
          tooltip: 'Back',
        ),
        Expanded(
          child: Center(
            child: GestureDetector(
              onTap: onShowSession,
              behavior: HitTestBehavior.opaque,
              child: OverlayPill(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      size: 18,
                      color: batch.isEmpty
                          ? AppColors.neutral
                          : AppColors.success,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      batch.isEmpty
                          ? 'BATCH · 0 SAVED'
                          : batch.skippedCount > 0
                          ? 'BATCH · ${batch.savedCount} SAVED · '
                                '${batch.skippedCount} SKIPPED'
                          : 'BATCH · ${batch.savedCount} SAVED',
                      style: AppTextStyles.label.copyWith(
                        fontSize: 12,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Opacity(
          opacity: batch.torchSupported ? 1 : 0.4,
          child: _SquareButton(
            size: 44,
            icon: batch.torchOn
                ? Icons.flash_off_outlined
                : Icons.flash_on_outlined,
            iconSize: 22,
            onTap: onFlash,
            tooltip: 'Flash',
          ),
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
              'Scan barcodes one after another',
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

class _BottomControls extends StatelessWidget {
  const _BottomControls({
    required this.batch,
    required this.pulse,
    required this.hint,
    required this.onManualEntry,
    required this.onShowSession,
    required this.onFinish,
  });

  final BatchScanProvider batch;
  final Animation<double> pulse;
  final String hint;
  final VoidCallback onManualEntry;
  final VoidCallback onShowSession;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 160, minHeight: 44),
          child: OverlayPill(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Center(
              widthFactor: 1,
              child: FadeTransition(
                opacity: pulse,
                child: Text(
                  'Batch scanning...',
                  style: AppTextStyles.headline.copyWith(
                    fontSize: 15,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: onShowSession,
                behavior: HitTestBehavior.opaque,
                child: OverlayPill(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      batch.isEmpty
                          ? '$hint · No items yet'
                          : '$hint · ${batch.items.length} in session',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.label.copyWith(
                        fontSize: 11,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            _SquareButton(
              size: 48,
              icon: Icons.keyboard_outlined,
              iconSize: 22,
              onTap: onManualEntry,
              tooltip: 'Manual entry',
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: Material(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onFinish,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.check_circle_outline,
                      size: 20,
                      color: AppColors.surfaceWhite,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Finish & Review',
                      style: AppTextStyles.headline.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.surfaceWhite,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Every item handled in this session, newest first. The camera is paused
/// while it is open.
class _SessionSheet extends StatelessWidget {
  const _SessionSheet();

  @override
  Widget build(BuildContext context) {
    final batch = context.read<BatchScanProvider>();
    final items = batch.items;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return FractionallySizedBox(
      heightFactor: 0.7,
      child: Material(
        color: AppColors.surfaceWhite,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'This session',
                      style: AppTextStyles.headline.copyWith(
                        fontSize: 18,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                    icon: const Icon(
                      Icons.close,
                      size: 20,
                      color: AppColors.neutral,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text(
                        'No barcodes scanned yet.',
                        style: AppTextStyles.body.copyWith(
                          fontSize: 14,
                          color: AppColors.neutral,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: items.length,
                      itemBuilder: (context, index) =>
                          _SessionTile(item: items[index]),
                    ),
            ),
            SizedBox(height: bottomInset),
          ],
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.item});

  final BatchScanItem item;

  @override
  Widget build(BuildContext context) {
    final saved = item.isSaved;
    final title = item.record.batchNumber ?? kUnrecognisedTitle;
    final detail = [
      if (item.record.gtin != null) 'GTIN: ${item.record.gtin}',
      item.record.barcodeFormat,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: saved ? AppColors.primaryTint : AppColors.warningTint,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              saved ? Icons.check_circle_outline : Icons.warning_amber_rounded,
              size: 22,
              color: saved ? AppColors.success : AppColors.warning,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.headline.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (detail.isNotEmpty)
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.label.copyWith(
                        fontSize: 11,
                        color: AppColors.neutral,
                      ),
                    ),
                ],
              ),
            ),
            Text(
              item.stateLabel,
              style: AppTextStyles.label.copyWith(
                fontSize: 11,
                color: saved ? AppColors.success : AppColors.warning,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
