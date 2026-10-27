import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../accuracy/accuracy_test_screen.dart';
import '../providers/history_provider.dart';
import '../services/camera_availability.dart';
import '../services/database_service.dart';
import '../theme/app_colors.dart';
import '../utils/constants.dart';
import '../utils/relative_time.dart';
import '../theme/app_text_styles.dart';
import '../widgets/action_card.dart';
import '../widgets/db_corruption_dialog.dart';
import '../widgets/info_chip.dart';
import '../widgets/stat_card.dart';
import 'batch_scan_screen.dart';
import 'history_screen.dart';
import 'manual_entry_screen.dart';
import 'scan_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _entrance;
  String _version = 'v1.0.0';

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 460), // 300ms + 80ms stagger x2
    )..forward();
    WidgetsBinding.instance.addObserver(this);
    _loadVersion();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _showCorruptionNotice(),
    );
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = 'v${info.version}');
    } catch (_) {
      // Keep fallback.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _entrance.dispose();
    super.dispose();
  }

  /// If the database had to be reset at startup, say so once the first load
  /// has finished.
  Future<void> _showCorruptionNotice() async {
    final history = context.read<HistoryProvider>();
    final db = context.read<DatabaseService>();
    if (history.isLoading) {
      final loaded = Completer<void>();
      void onChange() {
        if (!history.isLoading && !loaded.isCompleted) loaded.complete();
      }

      history.addListener(onChange);
      await loaded.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {},
      );
      history.removeListener(onChange);
    }
    if (!mounted) return;
    await showDbCorruptionDialogIfNeeded(context, db);
  }

  /// "Last Scan" is relative to now, so rebuild when the app resumes...
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  Widget _versionText() {
    final text = Text(
      _version,
      textAlign: TextAlign.center,
      style: AppTextStyles.label.copyWith(
        fontSize: 10,
        fontWeight: FontWeight.w400,
        letterSpacing: 1.5,
        color: AppColors.neutral.withValues(alpha: 0.7),
      ),
    );
    // Accuracy-test builds only (--dart-define=ACCURACY_TEST=true). The flag
    // is a compile-time constant, so in every other build this branch, the
    // gesture and the whole accuracy folder are removed from the app.
    if (kAccuracyTestEnabled) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _open(const AccuracyTestScreen()),
        child: Padding(padding: const EdgeInsets.all(8), child: text),
      );
    }
    return text;
  }

  void _showScanUnavailable() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text("Scanning isn't available on this device"),
        ),
      );
  }

  /// ...and when the user returns from another screen.
  Future<void> _open(Widget screen) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) setState(() {});
  }

  /// Stagger step [index]: each starts 80ms after the previous, lasts 300ms.
  Animation<double> _stagger(int index) {
    const total = 460.0;
    final start = index * 80 / total;
    return CurvedAnimation(
      parent: _entrance,
      curve: Interval(start, start + 300 / total, curve: Curves.easeOut),
    );
  }

  @override
  Widget build(BuildContext context) {
    // null while the launch-time check is still running: show nothing yet.
    final hasCamera = context.select<CameraAvailabilityProvider, bool?>(
      (c) => c.hasCamera,
    );
    final noCamera = hasCamera == false;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(onSettings: () => _open(const SettingsScreen())),
                const SizedBox(height: 16),
                const _Greeting(),
                const SizedBox(height: 20),
                if (noCamera) ...[
                  _NoCameraBanner(
                    onEnterManually: () => _open(const ManualEntryScreen()),
                  ),
                  const SizedBox(height: 12),
                ],
                _FadeSlideIn(
                  animation: _stagger(0),
                  child: Opacity(
                    opacity: noCamera ? 0.5 : 1,
                    child: ActionCard(
                      icon: Icons.qr_code_scanner,
                      title: 'Scan Barcode',
                      subtitle: 'Tap to open camera',
                      onTap: noCamera
                          ? _showScanUnavailable
                          : () => _open(const ScanScreen()),
                      backgroundColor: AppColors.primary,
                      tileColor: AppColors.background.withValues(alpha: 0.15),
                      iconColor: AppColors.background,
                      titleColor: AppColors.background,
                      subtitleColor: AppColors.background.withValues(
                        alpha: 0.85,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _FadeSlideIn(
                  animation: _stagger(1),
                  child: Opacity(
                    opacity: noCamera ? 0.5 : 1,
                    child: ActionCard(
                      icon: Icons.auto_awesome_motion_outlined,
                      title: 'Batch Scan',
                      subtitle: 'Scan many barcodes in one session',
                      onTap: noCamera
                          ? _showScanUnavailable
                          : () => _open(const BatchScanScreen()),
                      backgroundColor: AppColors.background,
                      borderColor: AppColors.tertiary,
                      tileColor: AppColors.primaryTint,
                      iconColor: AppColors.primary,
                      titleColor: AppColors.textPrimary,
                      subtitleColor: AppColors.neutral,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _FadeSlideIn(
                  animation: _stagger(2),
                  child: ActionCard(
                    icon: Icons.history,
                    title: 'Scan History',
                    subtitle: 'View, export, or clear saved scans',
                    onTap: () => _open(const HistoryScreen()),
                    backgroundColor: AppColors.background,
                    borderColor: AppColors.tertiary,
                    tileColor: AppColors.primaryTint,
                    iconColor: AppColors.primary,
                    titleColor: AppColors.textPrimary,
                    subtitleColor: AppColors.neutral,
                    trailing: const InfoChip(
                      icon: Icons.phone_android_outlined,
                      label: 'STORED LOCALLY',
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // Not const: `now` changes, so it rebuilds with this screen.
                _ScanActivity(now: DateTime.now()),
                const SizedBox(height: 16),
                const _ParserStrip(),
                const SizedBox(height: 32),
                _versionText(),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FadeSlideIn extends StatelessWidget {
  const _FadeSlideIn({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) => Opacity(
        opacity: animation.value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - animation.value)),
          child: child,
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onSettings});

  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Image.asset('assets/images/app_logo.png', width: 32, height: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              kAppName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.headline.copyWith(
                fontSize: 18,
                color: AppColors.primary,
              ),
            ),
          ),
          IconButton(
            onPressed: onSettings,
            tooltip: 'Settings',
            icon: const Icon(
              Icons.settings_outlined,
              size: 24,
              color: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hello 👋',
          style: AppTextStyles.headline.copyWith(
            fontSize: 28,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Scan GS1 pharma barcodes with precision',
          style: AppTextStyles.body.copyWith(
            fontSize: 14,
            color: AppColors.neutral,
          ),
        ),
      ],
    );
  }
}

class _ScanActivity extends StatelessWidget {
  const _ScanActivity({required this.now});

  final DateTime now;

  @override
  Widget build(BuildContext context) {
    // Only the two values the stats need, so unrelated history changes (paging,
    // search) do not rebuild Home.
    final (total, lastScanAt) = context
        .select<HistoryProvider, (int, DateTime?)>(
          (h) => (h.totalCount, h.lastScanAt),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SCAN ACTIVITY',
          style: AppTextStyles.label.copyWith(
            fontSize: 11,
            letterSpacing: 1.2,
            color: AppColors.neutral,
          ),
        ),
        const SizedBox(height: 10),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: StatCard(value: '$total', caption: 'Total Scans'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatCard(
                  value: lastScanAt == null
                      ? '—'
                      : formatRelativeTime(now, lastScanAt),
                  caption: 'Last Scan',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ParserStrip extends StatelessWidget {
  const _ParserStrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.infoTint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.inventory_2_outlined,
                size: 20,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'GS1 Parser Active',
                  style: AppTextStyles.headline.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Indent = icon (20) + gap (8) to align with the title text.
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Text(
              '(01) GTIN · (17) EXP · (10) LOT · (21) SN',
              style: AppTextStyles.label.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w400,
                color: AppColors.neutral,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the device has no usable camera.
class _NoCameraBanner extends StatelessWidget {
  const _NoCameraBanner({required this.onEnterManually});

  final VoidCallback onEnterManually;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      decoration: BoxDecoration(
        color: AppColors.warningTint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: AppColors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No camera found. Scanning is disabled, but you can enter '
                  'batch numbers manually and browse your history.',
                  style: AppTextStyles.body.copyWith(
                    fontSize: 13,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onEnterManually,
              child: Text(
                'Enter manually',
                style: AppTextStyles.body.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.warning,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
