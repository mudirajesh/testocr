import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/history_provider.dart';
import '../services/csv_export_service.dart' show ExportOutcome;
import '../services/database_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/debug_seed.dart';
import '../widgets/empty_scan_illustration.dart';
import '../widgets/history_card.dart';
import '../widgets/readiness_card.dart';
import '../widgets/scan_result_sheet.dart';
import 'scan_screen.dart';

const kEmptySubtitle =
    'Tap the scan button to begin verifying NDC codes and GS1 DataMatrix '
    'batches.';

/// Distance from the bottom (px) at which the next page starts loading.
const _loadMoreThreshold = 300.0;

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  late final HistoryProvider _history;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _history = context.read<HistoryProvider>();
    _scrollController.addListener(_onScroll);
    // A search left open on an earlier visit must not leak into this one.
    if (_history.searchQuery.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _history.clearSearch();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < _loadMoreThreshold) {
      _history.loadMore();
    }
  }

  void _toggleSearch() {
    if (_searching) {
      _closeSearch();
    } else {
      setState(() => _searching = true);
    }
  }

  void _closeSearch() {
    setState(() => _searching = false);
    _searchController.clear();
    _history.clearSearch();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Debug builds only (the gesture is not even wired in release builds).
  Future<void> _seed() async {
    await seedDebugScans(context.read<DatabaseService>());
    if (!mounted) return;
    await _history.refresh();
    if (mounted) _toast('Added debug scans');
  }

  // ------------------------------------------------------------------ export

  Future<void> _export({bool ignoreLowStorage = false}) async {
    if (_history.isExporting) return;
    if (_history.isEmptyLog) {
      _toast('No scan records to export');
      return;
    }

    final result = await _history.exportCsv(ignoreLowStorage: ignoreLowStorage);
    if (!mounted) return;

    switch (result.outcome) {
      case ExportOutcome.empty:
        _toast('No scan records to export');
      case ExportOutcome.lowStorage:
        final proceed = await showDialog<bool>(
          context: context,
          builder: (_) => const _LowStorageDialog(),
        );
        if (!mounted) return;
        if (proceed == true) await _export(ignoreLowStorage: true);
      case ExportOutcome.success:
        _toast('CSV exported successfully');
      case ExportOutcome.failed:
        _toast('Export failed. Please try again.');
    }
  }

  // -------------------------------------------------------------- clear all

  Future<void> _confirmClear() async {
    if (_history.isClearing) return;
    final count = await _history.freshTotalCount();
    final warn = await _history.shouldWarnNotExported();
    if (!mounted) return;
    if (count == 0) {
      _toast('No scan records to delete');
      return;
    }

    final action = await showDialog<_ClearAction>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ClearAllDialog(
        count: count,
        warnNotExported: warn,
        onConfirm: _history.clearAllRecords,
      ),
    );
    if (!mounted) return;

    switch (action) {
      case _ClearAction.deleted:
        // The provider already switched the list to the empty state.
        setState(() => _searching = false);
        _searchController.clear();
        _toast('All scan records deleted');
      case _ClearAction.failed:
        _toast('Could not delete records. Please try again.');
      case _ClearAction.exportFirst:
        await _export();
      case _ClearAction.cancel:
      case null:
        break;
    }
  }

  void _push(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppColors.background,
        floatingActionButton: _ScanFab(onTap: () => _push(const ScanScreen())),
        body: SafeArea(
          bottom: false,
          child: Consumer<HistoryProvider>(
            builder: (context, history, _) => _buildContent(history),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(HistoryProvider h) {
    final isEmptyLog = h.isEmptyLog;
    final hasQuery = h.searchQuery.isNotEmpty;
    final showSkeleton = h.isLoading && h.records.isEmpty;
    final showError = h.error != null && h.records.isEmpty && !h.isLoading;
    // Also covers the moment between typing and the debounced search running.
    final showNoMatches =
        hasQuery && h.records.isEmpty && !h.isLoading && h.totalCount > 0;

    final Widget body;
    if (showError) {
      body = RefreshIndicator(
        key: const ValueKey('error'),
        color: AppColors.primary,
        onRefresh: _history.refresh,
        child: _ErrorBody(onRetry: _history.retry),
      );
    } else if (showSkeleton) {
      body = const _SkeletonList(key: ValueKey('skeleton'));
    } else if (isEmptyLog) {
      body = RefreshIndicator(
        key: const ValueKey('empty'),
        color: AppColors.primary,
        onRefresh: _history.refresh,
        child: _EmptyBody(onScan: () => _push(const ScanScreen())),
      );
    } else if (showNoMatches) {
      body = RefreshIndicator(
        key: const ValueKey('no-matches'),
        color: AppColors.primary,
        onRefresh: _history.refresh,
        child: _NoMatchesBody(onClearSearch: _closeSearch),
      );
    } else {
      body = RefreshIndicator(
        key: const ValueKey('list'),
        color: AppColors.primary,
        onRefresh: _history.refresh,
        child: ListView.separated(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          itemCount: h.records.length + (h.isLoadingMore ? 1 : 0),
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, i) {
            if (i >= h.records.length) return const _LoadingMoreRow();
            final record = h.records[i];
            return HistoryCard(
              record: record,
              onTap: () => showScanResultSheet(
                context,
                record,
                mode: ScanSheetMode.detail,
              ),
            );
          },
        ),
      );
    }

    return Column(
      children: [
        _HistoryAppBar(
          onBack: () => Navigator.of(context).pop(),
          onSearch: isEmptyLog ? () => _toast('No scans yet') : _toggleSearch,
          onDownload: _export,
          exporting: h.isExporting,
          onProfile: () => _toast('Profile coming soon'),
          onTitleLongPress: kDebugMode ? _seed : null,
        ),
        if (isEmptyLog)
          const _EmptySubBar()
        else ...[
          _SubBar(
            label: h.isLoading
                ? 'Loading...'
                : '${h.totalCount} records logged',
            searching: _searching,
            controller: _searchController,
            onQueryChanged: _history.setSearchQuery,
            onSearch: _toggleSearch,
            onDownload: _export,
            exporting: h.isExporting,
            onDelete: _confirmClear,
          ),
          // While a search is active the field hides the record count, so the
          // match count takes the place of the protocol row.
          if (_searching && hasQuery)
            _ResultsCaption(text: '${h.matchCount} results')
          else
            const _ProtocolRow(),
        ],
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: body,
          ),
        ),
      ],
    );
  }
}

const _bottomDivider = BoxDecoration(
  border: Border(bottom: BorderSide(color: AppColors.tertiary)),
);

class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.tooltip,
    this.minSize = 44,
    this.busy = false,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String tooltip;
  final double minSize;

  /// Shows a small spinner instead of the icon and ignores taps.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: busy ? null : onTap,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
      icon: busy
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          : Icon(icon, size: 24, color: color),
    );
  }
}

class _HistoryAppBar extends StatelessWidget {
  const _HistoryAppBar({
    required this.onBack,
    required this.onSearch,
    required this.onDownload,
    required this.exporting,
    required this.onProfile,
    required this.onTitleLongPress,
  });

  final VoidCallback onBack;
  final VoidCallback onSearch;
  final VoidCallback onDownload;
  final bool exporting;
  final VoidCallback onProfile;
  final VoidCallback? onTitleLongPress;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: _bottomDivider,
      child: Row(
        children: [
          InkResponse(
            onTap: onBack,
            radius: 24,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(
                Icons.arrow_back,
                size: 24,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onLongPress: onTitleLongPress,
              behavior: HitTestBehavior.opaque,
              child: Text(
                'Scan Log Details',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.headline.copyWith(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ),
          _BarIconButton(
            icon: Icons.search,
            color: AppColors.textPrimary,
            onTap: onSearch,
            tooltip: 'Search',
            minSize: 36,
          ),
          const SizedBox(width: 8),
          _BarIconButton(
            icon: Icons.file_download_outlined,
            color: AppColors.textPrimary,
            onTap: onDownload,
            tooltip: 'Export',
            minSize: 36,
            busy: exporting,
          ),
          const SizedBox(width: 12),
          Material(
            color: AppColors.primaryDark,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onProfile,
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  Icons.person_outline,
                  size: 24,
                  color: AppColors.surfaceWhite,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubBar extends StatelessWidget {
  const _SubBar({
    required this.label,
    required this.searching,
    required this.controller,
    required this.onQueryChanged,
    required this.onSearch,
    required this.onDownload,
    required this.exporting,
    required this.onDelete,
  });

  final String label;
  final bool searching;
  final TextEditingController controller;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onSearch;
  final VoidCallback onDownload;
  final bool exporting;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: _bottomDivider,
      child: Row(
        children: [
          Expanded(
            child: searching
                ? _SearchField(
                    controller: controller,
                    onChanged: onQueryChanged,
                    onClose: onSearch,
                  )
                : Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.body.copyWith(
                            fontSize: 16,
                            color: AppColors.neutral,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(width: 4),
          _BarIconButton(
            icon: Icons.search,
            color: AppColors.primary,
            onTap: onSearch,
            tooltip: 'Search',
          ),
          const SizedBox(width: 12),
          _BarIconButton(
            icon: Icons.file_download_outlined,
            color: AppColors.primary,
            onTap: onDownload,
            tooltip: 'Export',
            busy: exporting,
          ),
          const SizedBox(width: 12),
          _BarIconButton(
            icon: Icons.delete_outline,
            color: AppColors.neutral,
            onTap: onDelete,
            tooltip: 'Clear all',
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      autofocus: true,
      style: AppTextStyles.body.copyWith(
        fontSize: 14,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search batch or GTIN',
        hintStyle: AppTextStyles.body.copyWith(
          fontSize: 14,
          color: AppColors.neutral,
        ),
        prefixIcon: const Icon(
          Icons.search,
          size: 20,
          color: AppColors.neutral,
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 36),
        suffixIcon: InkResponse(
          onTap: onClose,
          child: const Icon(Icons.close, size: 20, color: AppColors.neutral),
        ),
        suffixIconConstraints: const BoxConstraints(minWidth: 36),
        filled: true,
        fillColor: AppColors.tertiary,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _ProtocolRow extends StatelessWidget {
  const _ProtocolRow();

  @override
  Widget build(BuildContext context) {
    final labelStyle = AppTextStyles.label.copyWith(
      fontSize: 11,
      color: AppColors.neutral,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Text(
                'VERIFICATION PROTOCOL',
                style: labelStyle.copyWith(letterSpacing: 1),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.infoTint,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'GS1-128 / DataMatrix',
                  style: AppTextStyles.label.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryDark,
                  ),
                ),
              ),
            ],
          ),
          Text('Auto-sync: Active', style: labelStyle),
        ],
      ),
    );
  }
}

class _EmptySubBar extends StatelessWidget {
  const _EmptySubBar();

  @override
  Widget build(BuildContext context) {
    final disabled = AppColors.neutral.withValues(alpha: 0.4);

    Widget disabledIcon(IconData icon) => SizedBox(
      width: 44,
      height: 44,
      child: ExcludeSemantics(child: Icon(icon, size: 24, color: disabled)),
    );

    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: _bottomDivider,
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 4,
              children: [
                Text(
                  '0 records',
                  style: AppTextStyles.body.copyWith(
                    fontSize: 16,
                    color: AppColors.neutral,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.infoTint,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'EMPTY LOG',
                    style: AppTextStyles.label.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      color: AppColors.primaryDark,
                    ),
                  ),
                ),
              ],
            ),
          ),
          disabledIcon(Icons.search),
          const SizedBox(width: 12),
          disabledIcon(Icons.tune),
        ],
      ),
    );
  }
}

/// Illustration + title + subtitle (+ action) shared by both empty variants.
class _EmptyContent extends StatelessWidget {
  const _EmptyContent({
    required this.title,
    required this.subtitle,
    required this.action,
  });

  final String title;
  final String subtitle;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const EmptyScanIllustration(size: 100),
        const SizedBox(height: 24),
        Text(
          title,
          textAlign: TextAlign.center,
          style: AppTextStyles.headline.copyWith(
            fontSize: 20,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Text(
            subtitle,
            textAlign: TextAlign.center,
            style: AppTextStyles.body.copyWith(
              fontSize: 14,
              height: 1.5,
              color: AppColors.neutral,
            ),
          ),
        ),
        const SizedBox(height: 24),
        action,
      ],
    );
  }
}

class _EmptyBody extends StatelessWidget {
  const _EmptyBody({required this.onScan});

  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      child: _EmptyContent(
                        title: 'No scans yet',
                        subtitle: kEmptySubtitle,
                        action: _StartScanningButton(onTap: onScan),
                      ),
                    ),
                  ),
                ),
                // 88px clearance = 60px button + 16px margin + 12px gap.
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 88),
                  child: ReadinessCard(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Centered illustration + text + action, scrollable so pull-to-refresh works.
class _CenteredScrollable extends StatelessWidget {
  const _CenteredScrollable({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 96),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight - 16 - 96,
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _NoMatchesBody extends StatelessWidget {
  const _NoMatchesBody({required this.onClearSearch});

  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return _CenteredScrollable(
      child: _EmptyContent(
        title: 'No matches',
        subtitle: 'Try a different lot number or GTIN',
        action: TextButton(
          onPressed: onClearSearch,
          child: Text(
            'Clear search',
            style: AppTextStyles.body.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _CenteredScrollable(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40, color: AppColors.danger),
          const SizedBox(height: 16),
          Text(
            'Could not load scans',
            textAlign: TextAlign.center,
            style: AppTextStyles.headline.copyWith(
              fontSize: 18,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 20),
          TextButton(
            onPressed: onRetry,
            child: Text(
              'Try again',
              style: AppTextStyles.body.copyWith(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Six grey placeholder cards shown while the first page loads.
class _SkeletonList extends StatelessWidget {
  const _SkeletonList({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      itemCount: 6,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, _) => Container(
        height: 100,
        decoration: BoxDecoration(
          color: AppColors.tertiary.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.tertiary),
        ),
      ),
    );
  }
}

class _LoadingMoreRow extends StatelessWidget {
  const _LoadingMoreRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.primary,
          ),
        ),
      ),
    );
  }
}

/// "N results" shown under the sub-bar while a search is active.
class _ResultsCaption extends StatelessWidget {
  const _ResultsCaption({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: AppTextStyles.label.copyWith(
            fontSize: 11,
            letterSpacing: 1,
            color: AppColors.neutral,
          ),
        ),
      ),
    );
  }
}

class _StartScanningButton extends StatelessWidget {
  const _StartScanningButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.qr_code_scanner,
                  size: 20,
                  color: AppColors.surfaceWhite,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'Start Scanning',
                    style: AppTextStyles.headline.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.surfaceWhite,
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
}

class _ScanFab extends StatelessWidget {
  const _ScanFab({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: AppColors.shadow.withValues(alpha: 0.2),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: const SizedBox(
            width: 60,
            height: 60,
            child: Icon(
              Icons.qr_code_scanner,
              size: 28,
              color: AppColors.surfaceWhite,
            ),
          ),
        ),
      ),
    );
  }
}

class _LowStorageDialog extends StatelessWidget {
  const _LowStorageDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'Low storage',
        style: AppTextStyles.headline.copyWith(
          fontSize: 18,
          color: AppColors.textPrimary,
        ),
      ),
      content: Text(
        'Less than 5 MB of free space is left. The export may fail.',
        style: AppTextStyles.body.copyWith(
          fontSize: 14,
          color: AppColors.neutral,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            'Cancel',
            style: AppTextStyles.body.copyWith(
              fontWeight: FontWeight.w600,
              color: AppColors.neutral,
            ),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            'Export anyway',
            style: AppTextStyles.body.copyWith(
              fontWeight: FontWeight.w600,
              color: AppColors.primary,
            ),
          ),
        ),
      ],
    );
  }
}

enum _ClearAction { cancel, deleted, failed, exportFirst }

/// Confirmation for deleting everything. It cannot be dismissed by tapping
/// outside or with the back button, and it locks while the delete runs.
class _ClearAllDialog extends StatefulWidget {
  const _ClearAllDialog({
    required this.count,
    required this.warnNotExported,
    required this.onConfirm,
  });

  final int count;
  final bool warnNotExported;
  final Future<bool> Function() onConfirm;

  @override
  State<_ClearAllDialog> createState() => _ClearAllDialogState();
}

class _ClearAllDialogState extends State<_ClearAllDialog> {
  bool _deleting = false;

  Future<void> _delete() async {
    setState(() => _deleting = true);
    final ok = await widget.onConfirm();
    if (!mounted) return;
    Navigator.of(context).pop(ok ? _ClearAction.deleted : _ClearAction.failed);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.count;
    final body = n == 1
        ? 'This will permanently delete the 1 stored scan record.'
        : 'This will permanently delete all $n stored scan records.';

    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(
          'Clear All Scan Records?',
          style: AppTextStyles.headline.copyWith(
            fontSize: 18,
            color: AppColors.textPrimary,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$body This action cannot be undone. '
                'Consider exporting to CSV first.',
                style: AppTextStyles.body.copyWith(
                  fontSize: 14,
                  color: AppColors.neutral,
                ),
              ),
              if (widget.warnNotExported) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.warningTint,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'You have not exported your data recently.',
                    style: AppTextStyles.body.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.warning,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (widget.warnNotExported)
            TextButton(
              onPressed: _deleting
                  ? null
                  : () => Navigator.of(context).pop(_ClearAction.exportFirst),
              child: Text(
                'Export first',
                style: AppTextStyles.body.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ),
          TextButton(
            onPressed: _deleting
                ? null
                : () => Navigator.of(context).pop(_ClearAction.cancel),
            child: Text(
              'Cancel',
              style: AppTextStyles.body.copyWith(
                fontWeight: FontWeight.w600,
                color: AppColors.neutral,
              ),
            ),
          ),
          FilledButton(
            onPressed: _deleting ? null : _delete,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              disabledBackgroundColor: AppColors.danger.withValues(alpha: 0.6),
              foregroundColor: AppColors.surfaceWhite,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: _deleting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.surfaceWhite,
                    ),
                  )
                : Text(
                    'Delete All',
                    style: AppTextStyles.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppColors.surfaceWhite,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
