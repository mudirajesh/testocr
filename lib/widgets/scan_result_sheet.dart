import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/scan_record.dart';
import '../providers/scanner_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/batch_highlight.dart';
import '../utils/constants.dart';

enum ScanSheetMode {
  /// Valid scan, already saved.
  success,

  /// Questionable scan, not saved; the user must choose.
  warning,

  /// Read-only view of a stored record (reused by History later).
  detail,
}

enum ScanSheetAction { done, scanNext, saveAnyway, rescan, close, dismissed }

/// Shows the result sheet and resolves to what the user chose. Closing it any
/// other way (barrier tap, drag down, back) resolves to
/// [ScanSheetAction.dismissed].
Future<ScanSheetAction> showScanResultSheet(
  BuildContext context,
  ScanRecord record, {
  required ScanSheetMode mode,
  List<String> issues = const [],
  String? title,
  bool saveFailed = false,
}) async {
  final isWarning = mode == ScanSheetMode.warning;
  // The scanner provider already plays the success feedback.
  if (isWarning) HapticFeedback.heavyImpact();

  final action = await showModalBottomSheet<ScanSheetAction>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: AppColors.shadow.withValues(alpha: 0.4),
    useSafeArea: true,
    isDismissible: !isWarning,
    enableDrag: !isWarning,
    builder: (_) => ScanResultSheet(
      record: record,
      mode: mode,
      issues: issues,
      title: title,
      saveFailed: saveFailed,
    ),
  );
  return action ?? ScanSheetAction.dismissed;
}

class ScanResultSheet extends StatelessWidget {
  const ScanResultSheet({
    super.key,
    required this.record,
    required this.mode,
    this.issues = const [],
    this.title,
    this.saveFailed = false,
  });

  final ScanRecord record;
  final ScanSheetMode mode;
  final List<String> issues;
  final String? title;
  final bool saveFailed;

  bool get _isWarning => mode == ScanSheetMode.warning;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    // In warning mode the user must choose, so back is blocked as well.
    return PopScope(
      canPop: !_isWarning,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        shouldCloseOnMinExtent: !_isWarning,
        builder: (context, controller) {
          // A Material (not a plain DecoratedBox) so the ListTile inside the
          // raw-string expander can paint its ink.
          return Material(
            color: AppColors.surfaceWhite,
            clipBehavior: Clip.antiAlias,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SingleChildScrollView(
              controller: controller,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomInset),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _DragHandle(),
                  const SizedBox(height: 16),
                  _Header(
                    record: record,
                    mode: mode,
                    title: title,
                    issues: issues,
                  ),
                  if (saveFailed) ...[
                    const SizedBox(height: 16),
                    const _SaveFailedBanner(),
                  ],
                  if (_isWarning && issues.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _IssuesBox(issues: issues),
                  ],
                  if (record.imagePath != null &&
                      record.imagePath!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _CapturedImageCard(imagePath: record.imagePath!),
                  ],
                  if (record.medicineName != null || record.isOcr) ...[
                    const SizedBox(height: 16),
                    _MedicineVerificationCard(record: record),
                  ],
                  const SizedBox(height: 16),
                  _Details(record: record),
                  const SizedBox(height: 8),
                  _RawSection(raw: record.rawBarcode),
                  const SizedBox(height: 16),
                  _Buttons(mode: mode, saveFailed: saveFailed),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pure helpers

/// The raw string for display only: the GS control character is made visible.
@visibleForTesting
String visibleRaw(String raw) => raw.replaceAll('\u001D', '<GS>');

/// Whether the record carries no GS1 data at all (a plain QR, a URL, ...).
bool _hasNoGs1Fields(ScanRecord r) =>
    r.gtin == null &&
    r.batchNumber == null &&
    r.expiryDate == null &&
    r.serialNumber == null;

String _warningTitle(ScanRecord r, List<String> issues) {
  if (_hasNoGs1Fields(r) || issues.contains('Unrecognised barcode format')) {
    return 'Unrecognised barcode format';
  }
  final confidence = r.confidenceScore;
  if (confidence != null &&
      confidence < kConsensusRequired / kConsensusWindow) {
    return 'Low confidence scan';
  }
  return 'Check this scan';
}

// ---------------------------------------------------------------------------
// Pieces

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.neutral.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.record,
    required this.mode,
    required this.title,
    required this.issues,
  });

  final ScanRecord record;
  final ScanSheetMode mode;
  final String? title;
  final List<String> issues;

  @override
  Widget build(BuildContext context) {
    final warning =
        mode == ScanSheetMode.warning ||
        (mode == ScanSheetMode.detail && record.status == ScanStatus.alert);

    final String heading;
    final String subtitle;
    switch (mode) {
      case ScanSheetMode.success:
        heading = 'Scan Successful';
        subtitle = '${record.barcodeFormat} · Saved to history';
      case ScanSheetMode.warning:
        heading = _warningTitle(record, issues);
        subtitle = '${record.barcodeFormat} · Not saved yet';
      case ScanSheetMode.detail:
        heading = 'Scan Details';
        subtitle = record.barcodeFormat;
    }

    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: warning ? AppColors.warningTint : AppColors.primaryTint,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            warning ? Icons.warning_amber_rounded : Icons.check,
            size: 24,
            color: warning ? AppColors.warning : AppColors.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title ?? heading,
                style: AppTextStyles.headline.copyWith(
                  fontSize: 18,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: AppTextStyles.body.copyWith(
                  fontSize: 12,
                  color: AppColors.neutral,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SaveFailedBanner extends StatelessWidget {
  const _SaveFailedBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.dangerTint,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 20, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Could not save this scan. Try again.',
              style: AppTextStyles.body.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IssuesBox extends StatefulWidget {
  const _IssuesBox({required this.issues});

  final List<String> issues;

  @override
  State<_IssuesBox> createState() => _IssuesBoxState();
}

class _IssuesBoxState extends State<_IssuesBox> {
  static const _collapsedLines = 4;
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final all = widget.issues;
    final canCollapse = all.length > _collapsedLines;
    final shown = (!_showAll && canCollapse)
        ? all.take(_collapsedLines).toList()
        : all;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warningTint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final issue in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '•',
                    style: AppTextStyles.body.copyWith(
                      fontSize: 13,
                      color: AppColors.warning,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      issue,
                      style: AppTextStyles.body.copyWith(
                        fontSize: 13,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (canCollapse)
            GestureDetector(
              onTap: () => setState(() => _showAll = !_showAll),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  _showAll ? 'Show less' : 'Show all (${all.length})',
                  style: AppTextStyles.body.copyWith(
                    fontSize: 13,
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

class _Details extends StatelessWidget {
  const _Details({required this.record});

  final ScanRecord record;

  static final _timeFormat = DateFormat('dd MMM yyyy, HH:mm:ss');

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      _DetailRow(
        label: 'Batch Number',
        value: _BatchValue(batch: record.batchNumber),
        hint: _batchHasAmbiguous
            ? 'Highlighted characters (O or 0) look alike. '
                  'Check against the pack.'
            : null,
      ),
      _DetailRow(
        label: 'GTIN',
        value: _plain(
          record.gtin,
          AppTextStyles.label.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      if (record.medicineName != null)
        _DetailRow(
          label: 'Medicine',
          value: _plain(
            record.medicineName,
            AppTextStyles.label.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      if (record.strength != null)
        _DetailRow(
          label: 'Strength',
          value: _plain(
            record.strength,
            AppTextStyles.label.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      _DetailRow(label: 'Expiry Date', value: _expiryValue()),
      if (record.serialNumber != null)
        _DetailRow(
          label: 'Serial Number',
          value: _plain(
            record.serialNumber,
            AppTextStyles.label.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      if (record.confidencePercent != null)
        _DetailRow(
          label: 'Confidence',
          value: _ConfidenceChip(
            percent: record.confidencePercent!,
            high: (record.confidenceScore ?? 0) >= 0.8,
          ),
        ),
      _DetailRow(
        label: 'Scanned',
        value: _plain(
          _timeFormat.format(record.scanTimestamp),
          AppTextStyles.body.copyWith(
            fontSize: 14,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    ];

    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0)
            const Divider(height: 1, thickness: 1, color: AppColors.tertiary),
          rows[i],
        ],
      ],
    );
  }

  bool get _batchHasAmbiguous =>
      record.batchNumber != null &&
      ambiguousBatchPositions(record.batchNumber!).isNotEmpty;

  Widget _plain(String? value, TextStyle style) {
    if (value == null) return const _Dash();
    return Text(value, textAlign: TextAlign.end, style: style);
  }

  Widget _expiryValue() {
    final display = record.expiryDisplay;
    final raw = record.expiryDate;
    final style = AppTextStyles.headline.copyWith(
      fontSize: 15,
      color: AppColors.textPrimary,
    );
    if (display != null) return Text(display, style: style);
    if (raw == null) return const _Dash();
    // Present but not a real date: show it as read, flagged.
    return Text.rich(
      TextSpan(
        text: '$raw ',
        style: style,
        children: [
          TextSpan(
            text: '(invalid)',
            style: style.copyWith(color: AppColors.danger),
          ),
        ],
      ),
      textAlign: TextAlign.end,
    );
  }
}

class _Dash extends StatelessWidget {
  const _Dash();

  @override
  Widget build(BuildContext context) => Text(
    '—',
    style: AppTextStyles.body.copyWith(fontSize: 15, color: AppColors.neutral),
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.hint});

  final String label;
  final Widget value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                label,
                style: AppTextStyles.body.copyWith(
                  fontSize: 14,
                  color: AppColors.neutral,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Align(alignment: Alignment.centerRight, child: value),
              ),
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(
              hint!,
              style: AppTextStyles.body.copyWith(
                fontSize: 12,
                color: AppColors.warning,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The batch is the primary field: large and bold, with look-alike characters
/// (O/0) highlighted so they can be checked against the pack.
class _BatchValue extends StatelessWidget {
  const _BatchValue({required this.batch});

  final String? batch;

  @override
  Widget build(BuildContext context) {
    final value = batch;
    if (value == null || value.isEmpty) return const _Dash();

    final style = AppTextStyles.headline.copyWith(
      fontSize: 22,
      color: AppColors.primary,
    );
    return Text.rich(
      TextSpan(
        children: batchHighlightSpans(value, style, AppColors.warningTint),
      ),
      textAlign: TextAlign.end,
    );
  }
}

class _ConfidenceChip extends StatelessWidget {
  const _ConfidenceChip({required this.percent, required this.high});

  final String percent;
  final bool high;

  @override
  Widget build(BuildContext context) {
    final color = high ? AppColors.success : AppColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: high ? AppColors.successTint : AppColors.warningTint,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        percent,
        style: AppTextStyles.label.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _RawSection extends StatelessWidget {
  const _RawSection({required this.raw});

  final String raw;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          'Raw Barcode String',
          style: AppTextStyles.body.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.neutral,
          ),
        ),
        iconColor: AppColors.neutral,
        collapsedIconColor: AppColors.neutral,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.infoTint,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.15),
              ),
            ),
            child: SelectableText(
              visibleRaw(raw),
              style: AppTextStyles.label.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Buttons extends StatelessWidget {
  const _Buttons({required this.mode, required this.saveFailed});

  final ScanSheetMode mode;
  final bool saveFailed;

  @override
  Widget build(BuildContext context) {
    void pop(ScanSheetAction action) => Navigator.of(context).pop(action);

    switch (mode) {
      case ScanSheetMode.success:
        return Row(
          children: [
            Expanded(
              child: _SheetButton(
                label: 'Done',
                filled: false,
                onTap: () => pop(ScanSheetAction.done),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SheetButton(
                label: 'Scan Next',
                filled: true,
                onTap: () => pop(ScanSheetAction.scanNext),
              ),
            ),
          ],
        );
      case ScanSheetMode.warning:
        return Row(
          children: [
            Expanded(
              child: _SheetButton(
                label: 'Rescan',
                filled: false,
                onTap: () => pop(ScanSheetAction.rescan),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SheetButton(
                label: saveFailed ? 'Retry Save' : 'Save Anyway',
                filled: true,
                onTap: () => pop(ScanSheetAction.saveAnyway),
              ),
            ),
          ],
        );
      case ScanSheetMode.detail:
        return _SheetButton(
          label: 'Close',
          filled: false,
          onTap: () => pop(ScanSheetAction.close),
        );
    }
  }
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({
    required this.label,
    required this.filled,
    required this.onTap,
  });

  final String label;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: filled
          ? BorderSide.none
          : const BorderSide(color: AppColors.primary),
    );
    return Material(
      color: filled ? AppColors.primary : AppColors.surfaceWhite,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: AppTextStyles.headline.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: filled ? AppColors.surfaceWhite : AppColors.primary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CapturedImageCard extends StatelessWidget {
  const _CapturedImageCard({required this.imagePath});

  final String imagePath;

  @override
  Widget build(BuildContext context) {
    final file = File(imagePath);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 150,
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(color: AppColors.tertiary),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              file,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image_outlined, color: AppColors.neutral),
                    SizedBox(width: 8),
                    Text(
                      'Image not found',
                      style: TextStyle(color: AppColors.neutral, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.shadow.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.camera_alt, size: 14, color: AppColors.surfaceWhite),
                    SizedBox(width: 4),
                    Text(
                      'Captured Pack',
                      style: TextStyle(
                        color: AppColors.surfaceWhite,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MedicineVerificationCard extends StatefulWidget {
  const _MedicineVerificationCard({required this.record});

  final ScanRecord record;

  @override
  State<_MedicineVerificationCard> createState() =>
      _MedicineVerificationCardState();
}

class _MedicineVerificationCardState extends State<_MedicineVerificationCard> {
  late bool _verified;

  @override
  void initState() {
    super.initState();
    _verified = widget.record.verifiedByUser;
  }

  @override
  Widget build(BuildContext context) {
    final med = widget.record.medicineName ?? 'Medicine Detected';
    final strength = widget.record.strength;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _verified
            ? AppColors.successTint
            : (widget.record.isOcr
                ? AppColors.warningTint
                : AppColors.surfaceWhite),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _verified
              ? AppColors.success
              : (widget.record.isOcr
                  ? AppColors.warning
                  : AppColors.tertiary),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                widget.record.isOcr
                    ? Icons.document_scanner
                    : Icons.medication_outlined,
                color: widget.record.isOcr
                    ? AppColors.warning
                    : AppColors.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.record.isOcr
                      ? 'OCR Medicine Detection'
                      : 'Identified Medicine',
                  style: AppTextStyles.label.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    fontSize: 13,
                  ),
                ),
              ),
              if (_verified)
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle,
                        size: 16, color: AppColors.success),
                    SizedBox(width: 4),
                    Text(
                      'Verified',
                      style: TextStyle(
                        color: AppColors.success,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Name & Strength:',
                style: AppTextStyles.body.copyWith(
                  fontSize: 13,
                  color: AppColors.neutral,
                ),
              ),
              Text(
                strength != null ? '$med ($strength)' : med,
                style: AppTextStyles.headline.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          if (widget.record.isOcr) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surfaceWhite,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline,
                      size: 16, color: AppColors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Important: OCR reads printed text; it does not confirm a medicine\'s identity. Please verify the medicine name and strength on the packaging before relying on this result.',
                      style: AppTextStyles.body.copyWith(
                        fontSize: 12,
                        color: AppColors.textPrimary,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          InkWell(
            onTap: () {
              setState(() => _verified = !_verified);
              try {
                context
                    .read<ScannerProvider>()
                    .confirmMedicineVerification(_verified);
              } catch (_) {}
            },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Checkbox(
                    value: _verified,
                    onChanged: (val) {
                      setState(() => _verified = val ?? false);
                      try {
                        context
                            .read<ScannerProvider>()
                            .confirmMedicineVerification(_verified);
                      } catch (_) {}
                    },
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    activeColor: AppColors.success,
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'I confirm medicine name & strength match package',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
