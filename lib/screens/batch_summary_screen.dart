import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/batch_scan_item.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/constants.dart';

/// End of a batch scan session: what was scanned, what was saved and what was
/// skipped. The saved records are already in the history; the session data
/// itself is plain values copied from the provider before its camera stopped.
class BatchSummaryScreen extends StatelessWidget {
  const BatchSummaryScreen({super.key, required this.items});

  /// Newest first, as copied from the provider.
  final List<BatchScanItem> items;

  @override
  Widget build(BuildContext context) {
    final savedCount = items.where((i) => i.isSaved).length;
    final skipped = items.where((i) => !i.isSaved).toList();
    final failed = items.any((i) => i.state == BatchItemState.saveFailed);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Batch Session')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _HeaderCard(items: items, savedCount: savedCount),
                    const SizedBox(height: 20),
                    if (items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Column(
                          children: [
                            const Icon(
                              Icons.inventory_2_outlined,
                              size: 40,
                              color: AppColors.neutral,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No barcodes were scanned in this session.',
                              textAlign: TextAlign.center,
                              style: AppTextStyles.body.copyWith(
                                fontSize: 14,
                                color: AppColors.neutral,
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      _SectionLabel('SCANNED (${items.length})'),
                      const SizedBox(height: 8),
                      for (final item in items) _ItemTile(item: item),
                      if (skipped.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _SkippedNote(skipped: skipped, failed: failed),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton(
                onPressed: () =>
                    Navigator.of(context).popUntil((route) => route.isFirst),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.surfaceWhite,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  textStyle: AppTextStyles.headline.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.items, required this.savedCount});

  final List<BatchScanItem> items;
  final int savedCount;

  @override
  Widget build(BuildContext context) {
    final skipped = items.length - savedCount;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.successTint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              color: AppColors.success,
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            child: const Icon(
              Icons.task_alt,
              size: 26,
              color: AppColors.surfaceWhite,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Batch complete',
                  style: AppTextStyles.headline.copyWith(
                    fontSize: 18,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  skipped == 0
                      ? '$savedCount scans saved to history'
                      : '$savedCount saved · $skipped skipped',
                  style: AppTextStyles.body.copyWith(
                    fontSize: 13,
                    color: AppColors.neutral,
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTextStyles.label.copyWith(
        fontSize: 11,
        letterSpacing: 1.2,
        color: AppColors.neutral,
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});

  final BatchScanItem item;

  static final _timeFormat = DateFormat('HH:mm:ss');

  @override
  Widget build(BuildContext context) {
    final saved = item.isSaved;
    final record = item.record;
    final title = record.batchNumber ?? kUnrecognisedTitle;

    final detail = [
      if (record.gtin != null) 'GTIN: ${record.gtin}',
      if (record.expiryDisplay != null) 'EXP: ${record.expiryDisplay}',
      record.barcodeFormat,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surfaceWhite,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.tertiary),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(
                saved
                    ? Icons.check_circle_outline
                    : Icons.warning_amber_rounded,
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    item.stateLabel,
                    style: AppTextStyles.label.copyWith(
                      fontSize: 11,
                      color: saved ? AppColors.success : AppColors.warning,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _ItemTile._timeFormat.format(record.scanTimestamp),
                    style: AppTextStyles.label.copyWith(
                      fontSize: 10,
                      color: AppColors.neutral.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkippedNote extends StatelessWidget {
  const _SkippedNote({required this.skipped, required this.failed});

  final List<BatchScanItem> skipped;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warningTint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              failed
                  ? '${skipped.length} item(s) were not saved — including one '
                        'that could not be written. Scan it again on its own to '
                        'save it.'
                  : '${skipped.length} item(s) could not be read as GS1 '
                        'barcodes and were skipped. Use manual entry to add them.',
              style: AppTextStyles.body.copyWith(
                fontSize: 12,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
