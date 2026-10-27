import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/scan_record.dart';
import '../utils/constants.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import 'status_badge.dart';

class HistoryCard extends StatelessWidget {
  const HistoryCard({super.key, required this.record, required this.onTap});

  final ScanRecord record;
  final VoidCallback onTap;

  static final _dateFormat = DateFormat('dd MMM yyyy, HH:mm');

  @override
  Widget build(BuildContext context) {
    final isPass = record.status == ScanStatus.pass;
    final title = record.batchNumber ?? kUnrecognisedTitle;
    final date = _dateFormat.format(record.scanTimestamp);

    return Semantics(
      button: true,
      excludeSemantics: true,
      onTap: onTap,
      label:
          '$title, ${isPass ? 'pass' : 'alert'}, '
          'scanned ${date.replaceAll(',', '')}',
      child: Material(
        color: AppColors.surfaceWhite,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.tertiary),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: isPass ? AppColors.primary : AppColors.alertIconBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isPass ? Icons.check : Icons.warning_amber_rounded,
                    size: 24,
                    color: AppColors.surfaceWhite,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.headline.copyWith(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          StatusBadge(status: record.status),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _gtinLine(record),
                        style: AppTextStyles.label.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: AppColors.neutral,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        date,
                        style: AppTextStyles.label.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: AppColors.neutral.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  size: 24,
                  color: AppColors.neutral,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _gtinLine(ScanRecord r) {
    if (r.gtin != null) return 'GTIN: ${r.gtin}';
    if (r.barcodeFormat == kManualBarcodeFormat) return 'Manual entry';
    return 'GTIN: Not found';
  }
}
