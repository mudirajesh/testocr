import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/history_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/batch_highlight.dart';
import '../utils/constants.dart';
import '../utils/validators.dart';

/// Type a batch number (and optionally a GTIN) when a barcode cannot be
/// scanned. Pops with true after a successful save.
class ManualEntryScreen extends StatefulWidget {
  const ManualEntryScreen({super.key});

  @override
  State<ManualEntryScreen> createState() => _ManualEntryScreenState();
}

class _ManualEntryScreenState extends State<ManualEntryScreen> {
  final _batchController = TextEditingController();
  final _gtinController = TextEditingController();
  String? _batchError;
  String? _gtinError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _batchController.addListener(_onBatchChanged);
  }

  @override
  void dispose() {
    _batchController.dispose();
    _gtinController.dispose();
    super.dispose();
  }

  /// Hints follow what is typed; the value itself is never touched.
  void _onBatchChanged() => setState(() => _batchError = null);

  bool get _hasText => _batchController.text.isNotEmpty;

  /// Validates the trimmed values; sets the field errors and returns whether
  /// everything is acceptable.
  bool _validate(String batch, String gtin) {
    String? batchError;
    if (batch.isEmpty) {
      batchError = 'Enter a batch number';
    } else if (!isValidBatch(batch)) {
      batchError =
          'Batch number can be at most $kManualBatchMaxLength '
          'characters';
    }

    String? gtinError;
    if (gtin.isNotEmpty &&
        (gtin.length != 14 || !isValidGtinCheckDigit(gtin))) {
      gtinError = 'GTIN must be 14 digits with a valid check digit';
    }

    setState(() {
      _batchError = batchError;
      _gtinError = gtinError;
    });
    return batchError == null && gtinError == null;
  }

  Future<void> _save() async {
    // Trimmed only now, on save.
    final batch = _batchController.text.trim();
    final gtin = _gtinController.text.trim();
    if (!_validate(batch, gtin)) return;

    final history = context.read<HistoryProvider>();
    setState(() => _saving = true);
    try {
      await history.addManualRecord(
        batch: batch,
        gtin: gtin.isEmpty ? null : gtin,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      debugPrint('Manual entry save failed: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Could not save. Please try again.')),
        );
    }
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Discard entry?',
          style: AppTextStyles.headline.copyWith(
            fontSize: 18,
            color: AppColors.textPrimary,
          ),
        ),
        content: Text(
          'The batch number you typed has not been saved.',
          style: AppTextStyles.body.copyWith(
            fontSize: 14,
            color: AppColors.neutral,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Keep editing',
              style: AppTextStyles.body.copyWith(
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Discard',
              style: AppTextStyles.body.copyWith(
                fontWeight: FontWeight.w600,
                color: AppColors.danger,
              ),
            ),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final batch = _batchController.text;
    final charWarning = batchCharWarning(batch.trim());
    final hasAmbiguous = ambiguousBatchPositions(batch).isNotEmpty;

    return PopScope(
      canPop: !_hasText,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          surfaceTintColor: Colors.transparent,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          title: Text(
            'Manual Entry',
            style: AppTextStyles.headline.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Type the batch number if the barcode cannot be scanned.',
                  style: AppTextStyles.body.copyWith(
                    fontSize: 14,
                    color: AppColors.neutral,
                  ),
                ),
                const SizedBox(height: 20),
                _FieldLabel('Batch Number'),
                const SizedBox(height: 8),
                TextField(
                  controller: _batchController,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: kManualBatchMaxLength,
                  // Never cut or change what was typed or pasted: too long
                  // shows an error instead.
                  maxLengthEnforcement: MaxLengthEnforcement.none,
                  textInputAction: TextInputAction.next,
                  style: AppTextStyles.label.copyWith(
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                  decoration: _decoration(
                    hint: 'e.g. BN2024X981',
                    error: _batchError,
                  ),
                ),
                if (charWarning != null)
                  _HelperLine(text: charWarning, color: AppColors.warning),
                if (hasAmbiguous) ...[
                  const _HelperLine(
                    text: 'Check O (letter) vs 0 (zero) against the pack.',
                    color: AppColors.warning,
                  ),
                  const SizedBox(height: 8),
                  _HighlightPreview(batch: batch),
                ],
                const SizedBox(height: 20),
                _FieldLabel('GTIN (optional)'),
                const SizedBox(height: 8),
                TextField(
                  controller: _gtinController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 14,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) {
                    if (_gtinError != null) setState(() => _gtinError = null);
                  },
                  style: AppTextStyles.label.copyWith(
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                  decoration: _decoration(hint: '14 digits', error: _gtinError),
                ),
                const SizedBox(height: 24),
                Material(
                  color: _saving
                      ? AppColors.primary.withValues(alpha: 0.5)
                      : AppColors.primary,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _saving ? null : _save,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 52),
                      child: Center(
                        child: _saving
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.surfaceWhite,
                                ),
                              )
                            : Text(
                                'Save Entry',
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _decoration({required String hint, String? error}) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      hintText: hint,
      hintStyle: AppTextStyles.body.copyWith(
        fontSize: 15,
        color: AppColors.neutral.withValues(alpha: 0.7),
      ),
      errorText: error,
      errorStyle: AppTextStyles.body.copyWith(
        fontSize: 12,
        color: AppColors.danger,
      ),
      counterStyle: AppTextStyles.label.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        color: AppColors.neutral,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: border(AppColors.tertiary),
      focusedBorder: border(AppColors.primary, 2),
      errorBorder: border(AppColors.danger),
      focusedErrorBorder: border(AppColors.danger, 2),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTextStyles.body.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    );
  }
}

class _HelperLine extends StatelessWidget {
  const _HelperLine({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: AppTextStyles.body.copyWith(fontSize: 12, color: color),
      ),
    );
  }
}

/// The batch as typed, with O and 0 highlighted so they can be told apart.
class _HighlightPreview extends StatelessWidget {
  const _HighlightPreview({required this.batch});

  final String batch;

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyles.headline.copyWith(
      fontSize: 20,
      color: AppColors.primary,
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.infoTint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          Text(
            'Preview',
            style: AppTextStyles.body.copyWith(
              fontSize: 12,
              color: AppColors.neutral,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: batchHighlightSpans(
                  batch,
                  style,
                  AppColors.warningTint,
                ),
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
