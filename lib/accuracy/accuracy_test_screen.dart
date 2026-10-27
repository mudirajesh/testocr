import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../providers/scanner_provider.dart';
import '../services/barcode_scanner_service.dart';
import '../services/database_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/camera_preview_cover.dart';
import '../widgets/overlay_pill.dart';
import '../widgets/scan_frame.dart';
import 'accuracy_report.dart';
import 'accuracy_session.dart';

/// Writes the report files and opens the share sheet.
typedef ReportShare = Future<void> Function(List<File> files);

Future<void> _defaultShare(List<File> files) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [
        for (final f in files)
          XFile(
            f.path,
            mimeType: f.path.endsWith('.csv') ? 'text/csv' : 'text/markdown',
          ),
      ],
      subject: 'GS1 Scan accuracy report',
    ),
  );
}

Future<DeviceDetails> _defaultDeviceDetails() async {
  var model = 'unknown';
  var android = 'unknown';
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    model = '${info.manufacturer} ${info.model}'.trim();
    android = '${info.version.release} (API ${info.version.sdkInt})';
  } catch (e) {
    debugPrint('Device info unavailable: $e');
  }
  var appVersion = 'unknown';
  try {
    final package = await PackageInfo.fromPlatform();
    appVersion = '${package.version}+${package.buildNumber}';
  } catch (_) {}
  return DeviceDetails(
    model: model,
    androidVersion: android,
    appVersion: appVersion,
    buildMode: kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug',
  );
}

enum _Stage { setup, scanning, sampleSummary, sessionSummary }

/// Client acceptance test: scan each pack several times and measure how often
/// the extracted batch number matches the one printed on the pack.
///
/// It runs the real camera, consensus and parser pipeline with its own
/// ScannerProvider on a throw-away in-memory database, so the real history is
/// never touched. Only reachable in builds made with
/// `--dart-define=ACCURACY_TEST=true`.
class AccuracyTestScreen extends StatefulWidget {
  const AccuracyTestScreen({
    super.key,
    this.source,
    this.database,
    this.share,
    this.tempDir,
    this.deviceDetails,
  });

  /// Defaults to the real camera.
  final BarcodeDetectionSource? source;
  final DatabaseService? database;
  final ReportShare? share;
  final Future<Directory> Function()? tempDir;
  final Future<DeviceDetails> Function()? deviceDetails;

  @override
  State<AccuracyTestScreen> createState() => _AccuracyTestScreenState();
}

class _AccuracyTestScreenState extends State<AccuracyTestScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final AccuracySession _session = AccuracySession();
  late final ScannerProvider _scanner;
  late final DatabaseService _db;
  late final AnimationController _scanLine;

  _Stage _stage = _Stage.setup;

  // Setup form
  final _labelController = TextEditingController();
  final _batchController = TextEditingController();
  final _gtinController = TextEditingController();
  final Set<String> _tags = {};
  int _attemptCount = 10;
  String? _batchError;

  // Current sample
  SampleSetup? _setup;
  final List<AttemptRecord> _attempts = [];
  AttemptRecord? _lastAttempt;
  bool _showingResult = false;
  ScannerStatus? _lastStatus;

  // Export
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    // A throw-away in-memory database: the real history is never touched.
    _db = widget.database ?? DatabaseService.inMemory();
    _scanner = ScannerProvider(
      db: _db,
      source: widget.source ?? MlKitBarcodeSource(),
    );
    _scanner.addListener(_onScannerChanged);
    _scanLine = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanner.removeListener(_onScannerChanged);
    _scanner.dispose(); // also releases the camera
    unawaited(_db.close());
    _scanLine.dispose();
    _session.dispose();
    _labelController.dispose();
    _batchController.dispose();
    _gtinController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_stage != _Stage.scanning) return;
    if (state == AppLifecycleState.paused) {
      _scanner.onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      _scanner.onAppResumed();
    }
  }

  // --------------------------------------------------------------- flow

  void _startSample() {
    final batch = _batchController.text.trim();
    if (batch.isEmpty) {
      setState(() => _batchError = 'Type the batch number printed on the pack');
      return;
    }
    final label = _labelController.text.trim().isEmpty
        ? 'Sample ${_session.sampleCount + 1}'
        : _labelController.text.trim();
    final gtin = _gtinController.text.trim();

    _setup = SampleSetup(
      label: label,
      expectedBatch: batch,
      expectedGtin: gtin.isEmpty ? null : gtin,
      tags: [
        for (final t in kAccuracyConditionTags)
          if (_tags.contains(t)) t,
      ],
      attempts: _attemptCount,
    );
    _attempts.clear();
    _lastAttempt = null;
    _showingResult = false;
    _lastStatus = null;
    setState(() {
      _batchError = null;
      _stage = _Stage.scanning;
    });
    _scanLine.repeat(reverse: true);
    _scanner.start();
  }

  void _onScannerChanged() {
    final status = _scanner.status;
    if (status == _lastStatus) return;
    _lastStatus = status;

    final accepted =
        status == ScannerStatus.success ||
        status == ScannerStatus.needsReview ||
        status == ScannerStatus.lowConfidence;
    if (_stage == _Stage.scanning && !_showingResult && accepted) {
      _recordAccepted(status);
    }
    if (mounted) setState(() {});
  }

  void _recordAccepted(ScannerStatus status) {
    final setup = _setup;
    final record = _scanner.result;
    if (setup == null || record == null) return;

    final attempt = attemptFromScan(
      attemptNumber: _attempts.length + 1,
      expectedBatch: setup.expectedBatch,
      record: record,
      status: status.name,
      warnings: _scanner.issues,
      metrics: _scanner.lastMetrics,
    );
    _attempts.add(attempt);
    _lastAttempt = attempt;
    _showingResult = true;
    _scanLine.stop();
  }

  void _skipAttempt() {
    if (_showingResult) return;
    final attempt = AttemptRecord.failed(attemptNumber: _attempts.length + 1);
    _attempts.add(attempt);
    _lastAttempt = attempt;
    _showingResult = true;
    _scanLine.stop();
    setState(() {});
  }

  bool get _sampleDone => _attempts.length >= (_setup?.attempts ?? 0);

  void _nextAttempt() {
    if (_sampleDone) {
      _finishSample();
      return;
    }
    _showingResult = false;
    _lastAttempt = null;
    _lastStatus = null;
    _scanLine.repeat(reverse: true);
    _scanner.rescan();
    setState(() {});
  }

  Future<void> _finishSample() async {
    final setup = _setup;
    if (setup == null) return;
    _session.addSample(
      SampleResult(
        label: setup.label,
        tags: setup.tags,
        expectedBatch: setup.expectedBatch,
        expectedGtin: setup.expectedGtin,
        attempts: List.of(_attempts),
      ),
    );
    _scanLine.stop();
    await _scanner.stop(); // release the camera between samples
    if (!mounted) return;
    setState(() => _stage = _Stage.sampleSummary);
  }

  void _newSample() {
    _labelController.clear();
    _batchController.clear();
    _gtinController.clear();
    _tags.clear();
    setState(() => _stage = _Stage.setup);
  }

  Future<void> _shareReport() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final device = await (widget.deviceDetails ?? _defaultDeviceDetails)();
      final now = DateTime.now();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(now);
      final dir = await (widget.tempDir ?? getTemporaryDirectory)();

      final csv = File('${dir.path}/accuracy_report_$stamp.csv');
      // BOM first so spreadsheets read non-ASCII text correctly.
      await csv.writeAsBytes([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(buildAccuracyCsv(_session.samples, device)),
      ], flush: true);
      final md = File('${dir.path}/accuracy_report_$stamp.md');
      await md.writeAsString(
        buildAccuracyMarkdown(_session.summary, device, now),
        flush: true,
      );

      await (widget.share ?? _defaultShare)([csv, md]);
    } catch (e) {
      debugPrint('Accuracy report export failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('Could not export the report.')),
          );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.setup:
        return _buildSetup();
      case _Stage.scanning:
        return _buildScanning();
      case _Stage.sampleSummary:
        return _buildSampleSummary();
      case _Stage.sessionSummary:
        return _buildSessionSummary();
    }
  }

  // ------------------------------------------------------------- setup

  Widget _buildSetup() {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _appBar('Accuracy test'),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Sample ${_session.sampleCount + 1}',
                style: AppTextStyles.headline.copyWith(
                  fontSize: 22,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Type what is PRINTED on the pack. The scan is judged against '
                'it exactly (case-sensitive).',
                style: AppTextStyles.body.copyWith(
                  fontSize: 13,
                  color: AppColors.neutral,
                ),
              ),
              const SizedBox(height: 20),
              _label('Sample label'),
              _field(
                _labelController,
                hint: 'e.g. Paracetamol blister 3',
                caps: TextCapitalization.sentences,
              ),
              const SizedBox(height: 16),
              _label('Expected batch number'),
              _field(
                _batchController,
                hint: 'Exactly as printed, e.g. BN2024X981',
                error: _batchError,
                mono: true,
                caps: TextCapitalization.characters,
                onChanged: (_) {
                  if (_batchError != null) setState(() => _batchError = null);
                },
              ),
              const SizedBox(height: 16),
              _label('Expected GTIN (optional)'),
              _field(
                _gtinController,
                hint: '14 digits',
                mono: true,
                keyboard: TextInputType.number,
                formatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 16),
              _label('Conditions'),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final tag in kAccuracyConditionTags)
                    FilterChip(
                      label: Text(tag),
                      selected: _tags.contains(tag),
                      showCheckmark: false,
                      selectedColor: AppColors.primaryTint,
                      backgroundColor: AppColors.surfaceWhite,
                      side: BorderSide(
                        color: _tags.contains(tag)
                            ? AppColors.primary
                            : AppColors.tertiary,
                      ),
                      labelStyle: AppTextStyles.body.copyWith(
                        fontSize: 13,
                        color: _tags.contains(tag)
                            ? AppColors.primaryDark
                            : AppColors.textPrimary,
                      ),
                      onSelected: (on) => setState(() {
                        on ? _tags.add(tag) : _tags.remove(tag);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _label('Number of attempts'),
              Row(
                children: [
                  IconButton(
                    onPressed: _attemptCount > 1
                        ? () => setState(() => _attemptCount--)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                    tooltip: 'Fewer attempts',
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '$_attemptCount',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.headline.copyWith(
                        fontSize: 20,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _attemptCount < 50
                        ? () => setState(() => _attemptCount++)
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: 'More attempts',
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _PrimaryButton(label: 'Start scanning', onTap: _startSample),
              if (_session.sampleCount > 0) ...[
                const SizedBox(height: 12),
                _SecondaryButton(
                  label:
                      'Finish session (${_session.sampleCount} '
                      '${_session.sampleCount == 1 ? 'sample' : 'samples'})',
                  onTap: () => setState(() => _stage = _Stage.sessionSummary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  AppBar _appBar(String title) => AppBar(
    backgroundColor: AppColors.background,
    surfaceTintColor: Colors.transparent,
    foregroundColor: AppColors.textPrimary,
    elevation: 0,
    title: Text(
      title,
      style: AppTextStyles.headline.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
    ),
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: AppTextStyles.body.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    ),
  );

  Widget _field(
    TextEditingController controller, {
    required String hint,
    String? error,
    bool mono = false,
    TextCapitalization caps = TextCapitalization.none,
    TextInputType? keyboard,
    List<TextInputFormatter>? formatters,
    ValueChanged<String>? onChanged,
  }) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: width),
        );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: keyboard,
      inputFormatters: formatters,
      textCapitalization: caps,
      autocorrect: false,
      enableSuggestions: false,
      style: (mono ? AppTextStyles.label : AppTextStyles.body).copyWith(
        fontSize: 16,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: hint,
        errorText: error,
        hintStyle: AppTextStyles.body.copyWith(
          fontSize: 14,
          color: AppColors.neutral.withValues(alpha: 0.7),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        enabledBorder: border(AppColors.tertiary),
        focusedBorder: border(AppColors.primary, 2),
        errorBorder: border(AppColors.danger),
        focusedErrorBorder: border(AppColors.danger, 2),
      ),
    );
  }

  // ---------------------------------------------------------- scanning

  Widget _buildScanning() {
    final setup = _setup!;
    final size = MediaQuery.sizeOf(context);
    final status = _scanner.status;
    final attemptNumber = _showingResult
        ? _attempts.length
        : _attempts.length + 1;

    final cameraProblem =
        status == ScannerStatus.permissionDenied ||
        status == ScannerStatus.noCamera ||
        status == ScannerStatus.error;

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
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [AppColors.mockCameraTop, AppColors.mockCameraBottom],
                ),
              ),
            ),
            if (_scanner.cameraController != null)
              CameraPreviewCover(controller: _scanner.cameraController!),
            const ColoredBox(color: AppColors.scrim),
            if (!cameraProblem)
              Positioned(
                top: size.height * 0.30,
                left: 30,
                width: size.width - 60,
                height: (size.width - 60) * 0.65,
                child: ScanFrame(lineAnimation: _scanLine),
              ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OverlayPill(
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${setup.label}  ·  Attempt $attemptNumber '
                                  'of ${setup.attempts}',
                                  style: AppTextStyles.headline.copyWith(
                                    fontSize: 14,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Expected: ${setup.expectedBatch}',
                                  style: AppTextStyles.label.copyWith(
                                    fontSize: 12,
                                    color: AppColors.primaryDark,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => _confirmEndSample(),
                            tooltip: 'End this sample',
                            icon: const Icon(
                              Icons.close,
                              color: AppColors.neutral,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    if (cameraProblem)
                      _ProblemCard(
                        onRetry: _scanner.start,
                        onClose: _confirmEndSample,
                      )
                    else if (_showingResult)
                      _ResultCard(
                        attempt: _lastAttempt!,
                        expected: setup.expectedBatch,
                        isLast: _sampleDone,
                        onNext: _nextAttempt,
                      )
                    else ...[
                      OverlayPill(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            _statusLabel(status),
                            style: AppTextStyles.headline.copyWith(
                              fontSize: 16,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _SecondaryButton(
                        label: 'Skip / could not scan',
                        onTap: _skipAttempt,
                        onDark: true,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(ScannerStatus status) {
    switch (status) {
      case ScannerStatus.initializing:
        return 'Starting camera...';
      case ScannerStatus.scanning:
        return 'Scanning...';
      case ScannerStatus.processing:
        return 'Processing...';
      default:
        return 'Scanning...';
    }
  }

  Future<void> _confirmEndSample() async {
    final end = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'End this sample?',
          style: AppTextStyles.headline.copyWith(
            fontSize: 18,
            color: AppColors.textPrimary,
          ),
        ),
        content: Text(
          _attempts.isEmpty
              ? 'No attempts were recorded for it.'
              : '${_attempts.length} attempt(s) recorded so far will be kept.',
          style: AppTextStyles.body.copyWith(
            fontSize: 14,
            color: AppColors.neutral,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep scanning'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('End sample'),
          ),
        ],
      ),
    );
    if (end != true || !mounted) return;
    if (_attempts.isEmpty) {
      _scanLine.stop();
      await _scanner.stop();
      if (mounted) setState(() => _stage = _Stage.setup);
    } else {
      await _finishSample();
    }
  }

  // --------------------------------------------------- sample summary

  Widget _buildSampleSummary() {
    final sample = _session.samples.last;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _appBar('Sample result'),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                sample.label,
                style: AppTextStyles.headline.copyWith(
                  fontSize: 22,
                  color: AppColors.textPrimary,
                ),
              ),
              if (sample.tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    sample.tags.join(' · '),
                    style: AppTextStyles.body.copyWith(
                      fontSize: 13,
                      color: AppColors.neutral,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              _BigVerdict(
                title: 'Correct ${sample.correctCount} of ${sample.total}',
                subtitle: _percent(sample.accuracy),
                pass: !sample.belowThreshold,
              ),
              const SizedBox(height: 16),
              _StatRow('Median scan time', _ms(sample.medianMs)),
              _StatRow('95th percentile', _ms(sample.p95Ms)),
              _StatRow('Expected batch', sample.expectedBatch, mono: true),
              if (sample.wrongAttempts.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Wrong extractions',
                  style: AppTextStyles.headline.copyWith(
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                for (final a in sample.wrongAttempts)
                  _WrongAttemptTile(attempt: a, expected: sample.expectedBatch),
              ],
              const SizedBox(height: 24),
              _PrimaryButton(label: 'Next sample', onTap: _newSample),
              const SizedBox(height: 12),
              _SecondaryButton(
                label: 'Finish session',
                onTap: () => setState(() => _stage = _Stage.sessionSummary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------- session summary

  Widget _buildSessionSummary() {
    final summary = _session.summary;
    final overall = summary.overallVerdict;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _appBar('Session summary'),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BigVerdict(
                title:
                    '${verdictLabel(overall)} · '
                    '${summary.correctAttempts} of ${summary.totalAttempts} '
                    'correct',
                subtitle: _percent(summary.accuracy),
                pass: overall == Verdict.pass,
                neutral: overall == Verdict.noData,
              ),
              const SizedBox(height: 12),
              _VerdictLine(
                'Accuracy ≥ $kAccuracyThresholdPercent%',
                summary.accuracyVerdict,
                _percent(summary.accuracy),
              ),
              _VerdictLine(
                'Scan time ≤ ${kScanTimeTargetMs / 1000} s (95th percentile)',
                summary.timeVerdict,
                _ms(summary.p95Ms),
              ),
              const SizedBox(height: 12),
              _StatRow('Median scan time', _ms(summary.medianMs)),
              _StatRow('95th percentile', _ms(summary.p95Ms)),
              _StatRow(
                'Attempts over ${kScanTimeTargetMs / 1000} s',
                '${summary.attemptsOverTarget}',
              ),
              _StatRow(
                'Samples below $kAccuracyThresholdPercent%',
                '${summary.samplesBelowThreshold} of ${summary.samples.length}',
              ),
              if (summary.tagStats.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'By condition',
                  style: AppTextStyles.headline.copyWith(
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                for (final t in summary.tagStats)
                  _StatRow(
                    t.tag,
                    '${t.correct}/${t.total}  ${_percent(t.accuracy)}',
                  ),
              ],
              if (summary.samples.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Samples',
                  style: AppTextStyles.headline.copyWith(
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                for (final s in summary.samples)
                  _StatRow(
                    s.label,
                    '${s.correctCount}/${s.total}  ${_percent(s.accuracy)}',
                    flagged: s.belowThreshold,
                  ),
              ],
              const SizedBox(height: 24),
              _PrimaryButton(
                label: _sharing ? 'Preparing report...' : 'Share report',
                onTap: summary.isEmpty ? null : _shareReport,
              ),
              const SizedBox(height: 12),
              _SecondaryButton(label: 'Add another sample', onTap: _newSample),
              const SizedBox(height: 12),
              _SecondaryButton(
                label: 'Start a new session',
                onTap: () {
                  _session.clear();
                  _newSample();
                },
              ),
              const SizedBox(height: 12),
              _SecondaryButton(
                label: 'Close',
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _percent(double? v) =>
    v == null ? 'n/a' : '${(v * 100).toStringAsFixed(1)}%';

String _ms(num? v) => v == null ? 'n/a' : '${v is double ? v.round() : v} ms';

// ---------------------------------------------------------------------------
// Pieces

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.attempt,
    required this.expected,
    required this.isLast,
    required this.onNext,
  });

  final AttemptRecord attempt;
  final String expected;
  final bool isLast;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final ok = attempt.correct;
    final color = ok ? AppColors.success : AppColors.danger;
    final slow =
        attempt.scanToResultMs != null &&
        attempt.scanToResultMs! > kScanTimeTargetMs;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: OverlayPill.shadows,
      ),
      child: Material(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    ok ? Icons.check_circle : Icons.cancel,
                    color: color,
                    size: 28,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      attempt.skipped
                          ? 'Not scanned'
                          : (ok ? 'Correct' : 'Wrong'),
                      style: AppTextStyles.headline.copyWith(
                        fontSize: 18,
                        color: color,
                      ),
                    ),
                  ),
                  if (attempt.scanToResultMs != null)
                    Text(
                      '${attempt.scanToResultMs} ms',
                      style: AppTextStyles.label.copyWith(
                        fontSize: 13,
                        color: slow ? AppColors.warning : AppColors.neutral,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (!attempt.skipped) ...[
                _DiffLine(
                  label: 'Expected',
                  chars: diffCharacters(
                    expected,
                    attempt.extractedBatch ?? '',
                  ).expected,
                ),
                const SizedBox(height: 4),
                _DiffLine(
                  label: 'Got',
                  chars: diffCharacters(
                    expected,
                    attempt.extractedBatch ?? '',
                  ).actual,
                  empty: attempt.extractedBatch == null
                      ? '(no batch found)'
                      : null,
                ),
                const SizedBox(height: 6),
                Text(
                  '${attempt.status}'
                  '${attempt.confidence == null ? '' : ' · ${(attempt.confidence! * 100).round()}%'}',
                  style: AppTextStyles.label.copyWith(
                    fontSize: 11,
                    color: AppColors.neutral,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              _PrimaryButton(
                label: isLast ? 'See sample result' : 'Next attempt',
                onTap: onNext,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiffLine extends StatelessWidget {
  const _DiffLine({required this.label, required this.chars, this.empty});

  final String label;
  final List<DiffChar> chars;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: AppTextStyles.body.copyWith(
              fontSize: 12,
              color: AppColors.neutral,
            ),
          ),
        ),
        Expanded(
          child: DiffText(chars: chars, empty: empty),
        ),
      ],
    );
  }
}

/// A string with the differing characters highlighted.
class DiffText extends StatelessWidget {
  const DiffText({super.key, required this.chars, this.empty});

  final List<DiffChar> chars;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    final base = AppTextStyles.label.copyWith(
      fontSize: 15,
      color: AppColors.textPrimary,
    );
    if (chars.isEmpty) {
      return Text(empty ?? '—', style: base.copyWith(color: AppColors.neutral));
    }
    return Text.rich(
      TextSpan(
        children: [
          for (final c in chars)
            TextSpan(
              text: c.char,
              style: c.differs
                  ? base.copyWith(
                      backgroundColor: AppColors.dangerTint,
                      color: AppColors.danger,
                      fontWeight: FontWeight.w700,
                    )
                  : base,
            ),
        ],
      ),
    );
  }
}

class _WrongAttemptTile extends StatelessWidget {
  const _WrongAttemptTile({required this.attempt, required this.expected});

  final AttemptRecord attempt;
  final String expected;

  @override
  Widget build(BuildContext context) {
    final diff = diffCharacters(expected, attempt.extractedBatch ?? '');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.dangerTint,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            attempt.skipped
                ? 'Attempt ${attempt.attemptNumber}: not scanned'
                : 'Attempt ${attempt.attemptNumber}',
            style: AppTextStyles.body.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.danger,
            ),
          ),
          if (!attempt.skipped) ...[
            const SizedBox(height: 6),
            _DiffLine(label: 'Expected', chars: diff.expected),
            const SizedBox(height: 2),
            _DiffLine(
              label: 'Actual',
              chars: diff.actual,
              empty: '(no batch found)',
            ),
          ],
        ],
      ),
    );
  }
}

class _BigVerdict extends StatelessWidget {
  const _BigVerdict({
    required this.title,
    required this.subtitle,
    required this.pass,
    this.neutral = false,
  });

  final String title;
  final String subtitle;
  final bool pass;
  final bool neutral;

  @override
  Widget build(BuildContext context) {
    final color = neutral
        ? AppColors.neutral
        : (pass ? AppColors.success : AppColors.danger);
    final tint = neutral
        ? AppColors.tertiary
        : (pass ? AppColors.successTint : AppColors.dangerTint);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            neutral
                ? Icons.help_outline
                : (pass ? Icons.check_circle : Icons.cancel),
            color: color,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.headline.copyWith(
                    fontSize: 17,
                    color: color,
                  ),
                ),
                Text(
                  subtitle,
                  style: AppTextStyles.label.copyWith(
                    fontSize: 13,
                    color: color,
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

class _VerdictLine extends StatelessWidget {
  const _VerdictLine(this.label, this.verdict, this.value);

  final String label;
  final Verdict verdict;
  final String value;

  @override
  Widget build(BuildContext context) {
    final color = switch (verdict) {
      Verdict.pass => AppColors.success,
      Verdict.fail => AppColors.danger,
      Verdict.noData => AppColors.neutral,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              verdictLabel(verdict),
              style: AppTextStyles.label.copyWith(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: AppTextStyles.body.copyWith(
                fontSize: 13,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Text(
            value,
            style: AppTextStyles.label.copyWith(
              fontSize: 12,
              color: AppColors.neutral,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow(
    this.label,
    this.value, {
    this.mono = false,
    this.flagged = false,
  });

  final String label;
  final String value;
  final bool mono;
  final bool flagged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: AppTextStyles.body.copyWith(
                fontSize: 14,
                color: AppColors.neutral,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: (mono ? AppTextStyles.label : AppTextStyles.headline)
                  .copyWith(
                    fontSize: 14,
                    color: flagged ? AppColors.danger : AppColors.textPrimary,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProblemCard extends StatelessWidget {
  const _ProblemCard({required this.onRetry, required this.onClose});

  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'The camera is not available',
            style: AppTextStyles.headline.copyWith(
              fontSize: 16,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          _PrimaryButton(label: 'Try again', onTap: onRetry),
          const SizedBox(height: 8),
          _SecondaryButton(label: 'End sample', onTap: onClose),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onTap == null
          ? AppColors.primary.withValues(alpha: 0.5)
          : AppColors.primary,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Center(
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
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({
    required this.label,
    required this.onTap,
    this.onDark = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onDark ? AppColors.surfaceWhite : AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: onDark ? AppColors.surfaceWhite : AppColors.primary,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: AppTextStyles.headline.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
