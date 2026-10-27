import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const _totalDuration = Duration(milliseconds: 2500);
  static const _fadeInDuration = Duration(milliseconds: 600);
  static const _transitionDuration = Duration(milliseconds: 400);

  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  Timer? _navTimer;
  String _version = 'v1.0.0';

  @override
  void initState() {
    super.initState();
    // One controller drives both the fade-in (first 600ms) and the progress
    // bar (full 2500ms).
    _controller = AnimationController(vsync: this, duration: _totalDuration)
      ..forward();
    _fadeIn = CurvedAnimation(
      parent: _controller,
      curve: Interval(
        0,
        _fadeInDuration.inMilliseconds / _totalDuration.inMilliseconds,
        curve: Curves.easeOut,
      ),
    );
    _navTimer = Timer(_totalDuration, _goHome);
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = 'v${info.version}');
    } catch (_) {
      // Keep the fallback version.
    }
  }

  void _goHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: _transitionDuration,
        pageBuilder: (_, _, _) => const HomeScreen(),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _navTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final h = size.height;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.surfaceTint, AppColors.background],
            ),
          ),
          child: SafeArea(
            child: FadeTransition(
              opacity: _fadeIn,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // ~32% from the top of the screen, measured within the
                  final maxGap = constraints.maxHeight * 0.4;
                  final topGap = maxGap <= 16.0
                      ? 16.0
                      : (h * 0.32 - MediaQuery.paddingOf(context).top).clamp(16.0, maxGap);
                  return Column(
                    children: [
                      SizedBox(height: topGap),
                      const _LogoCard(),
                      const SizedBox(height: 20),
                      Text(
                        'GS1 Scan',
                        style: AppTextStyles.headline.copyWith(
                          fontSize: 32,
                          color: AppColors.primary,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _InfoBadge(
                              icon: Icons.verified_outlined,
                              label: 'GS1 Compliant',
                            ),
                            _InfoBadge(
                              icon: Icons.qr_code_scanner,
                              label: '2D DataMatrix Certified',
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      _ProgressBar(animation: _controller),
                      const SizedBox(height: 20),
                      _Footer(version: _version),
                      const SizedBox(height: 24),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LogoCard extends StatelessWidget {
  const _LogoCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      height: 140,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadow.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Image.asset('assets/images/app_logo.png', fit: BoxFit.contain),
    );
  }
}

class _InfoBadge extends StatelessWidget {
  const _InfoBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.tertiary,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: AppTextStyles.label.copyWith(
              fontSize: 11,
              color: AppColors.primaryDark,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.animation});

  final Animation<double> animation;

  static const double _width = 120;
  static const double _height = 3;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _width,
      height: _height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final fill = _width * animation.value;
            return Stack(
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: AppColors.tertiary),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: fill,
                  child: const ColoredBox(color: AppColors.primary),
                ),
                // Subtle glowing highlight at the leading edge.
                if (animation.value > 0 && animation.value < 1)
                  Positioned(
                    left: fill - 2,
                    top: 0,
                    bottom: 0,
                    width: 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppColors.secondary,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.secondary.withValues(alpha: 0.6),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/images/koolmind_logo.png',
              width: 16,
              height: 16,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 8),
            Text(
              'Powered by KoolMind Technolab',
              style: AppTextStyles.label.copyWith(
                fontSize: 11,
                color: AppColors.neutral,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          version,
          textAlign: TextAlign.center,
          style: AppTextStyles.label.copyWith(
            fontSize: 10,
            fontWeight: FontWeight.w400,
            color: AppColors.neutral.withValues(alpha: 0.7),
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}
