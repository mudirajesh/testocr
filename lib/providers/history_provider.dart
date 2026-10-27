// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/scan_record.dart';
import '../services/csv_export_service.dart';
import '../services/database_service.dart';
import '../services/export_tracker.dart';
import '../utils/constants.dart';

/// Paged, searchable scan history backed by [DatabaseService]. Also feeds the
/// Home stats (total count and last scan time).
class HistoryProvider extends ChangeNotifier {
  HistoryProvider(
    this._db, {
    Duration searchDebounce = const Duration(milliseconds: 300),
    CsvExportService? exporter,
    ExportTracker? tracker,
  }) : _searchDebounce = searchDebounce,
       _exporter = exporter ?? CsvExportService(db: _db),
       _tracker = tracker ?? ExportTracker();

  final DatabaseService _db;
  final CsvExportService _exporter;
  final ExportTracker _tracker;
  final Duration _searchDebounce;

  List<ScanRecord> _records = [];
  int _matchCount = 0;
  int _totalCount = 0;
  DateTime? _lastScanAt;
  bool _isLoading = true; // the first page has not arrived yet
  bool _isLoadingMore = false;
  bool _hasMore = false;
  String _searchQuery = '';
  Object? _error;

  /// The query the current [records] were loaded for. Differs from
  /// [searchQuery] while a debounced search has not run yet.
  String _loadedQuery = '';

  Timer? _debounce;
  bool _disposed = false;
  bool _isExporting = false;
  bool _isClearing = false;

  /// Bumped by every reload. A result that finds a newer number was started
  /// after it is stale and is discarded (slow query vs. newer search).
  int _generation = 0;

  List<ScanRecord> get records => List.unmodifiable(_records);

  /// Rows matching the current search (all rows when there is no search).
  int get matchCount => _matchCount;

  /// All rows, ignoring any search.
  int get totalCount => _totalCount;
  DateTime? get lastScanAt => _lastScanAt;

  /// True while the first page is loading.
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _hasMore;
  String get searchQuery => _searchQuery;
  Object? get error => _error;

  bool get isExporting => _isExporting;
  bool get isClearing => _isClearing;

  bool get isEmptyLog => totalCount == 0 && !isLoading;

  bool get isNoMatches =>
      searchQuery.isNotEmpty &&
      _loadedQuery == searchQuery &&
      records.isEmpty &&
      !isLoading &&
      totalCount > 0;

  /// First page, with the loading flag on (app start, retry).
  Future<void> loadInitial() => _reload(showLoading: true);

  /// Reload from the start while keeping the current list visible.
  Future<void> refresh() => _reload(showLoading: false);

  Future<void> retry() => loadInitial();

  Future<void> loadMore() async {
    if (_isLoadingMore || _isLoading || !_hasMore) return;
    final generation = _generation;
    _isLoadingMore = true;
    notifyListeners();
    try {
      final page = await _db.getPage(
        offset: _records.length,
        batchQuery: _loadedQuery,
      );
      if (generation != _generation) return; // a reload replaced the list
      final known = {for (final r in _records) r.id};
      _records = [
        ..._records,
        for (final r in page)
          if (!known.contains(r.id)) r,
      ];
      _hasMore = page.length == kHistoryPageSize;
    } catch (e, st) {
      debugPrint('HistoryProvider.loadMore failed: $e\n$st');
      if (generation == _generation) _error = e;
    } finally {
      if (generation == _generation) {
        _isLoadingMore = false;
        notifyListeners();
      }
    }
  }

  /// Debounced (300 ms) search by batch or GTIN. An empty query clears the
  /// search immediately.
  void setSearchQuery(String query) {
    final trimmed = query.trim();
    if (trimmed == _searchQuery) return;
    _searchQuery = trimmed;
    _debounce?.cancel();

    if (trimmed.isEmpty) {
      _reload(showLoading: false);
    } else {
      notifyListeners(); // show the new text right away
      _debounce = Timer(_searchDebounce, () => _reload(showLoading: false));
    }
  }

  void clearSearch() => setSearchQuery('');

  /// Deletes every record. The confirmation flow is built in Step 6.
  Future<void> clearAll() async {
    _debounce?.cancel();
    await _db.deleteAll();
    _generation++;
    _records = [];
    _matchCount = 0;
    _totalCount = 0;
    _lastScanAt = null;
    _searchQuery = '';
    _loadedQuery = '';
    _hasMore = false;
    _isLoading = false;
    _isLoadingMore = false;
    _error = null;
    notifyListeners();
  }

  /// Saves a batch number typed by hand. Throws if the database write fails
  /// (the caller shows the error); a failed refresh afterwards is not fatal.
  Future<ScanRecord> addManualRecord({
    required String batch,
    String? gtin,
  }) async {
    final record = ScanRecord.create(
      rawBarcode: batch,
      barcodeFormat: kManualBarcodeFormat,
      batchNumber: batch,
      gtin: gtin,
      confidenceScore: null,
      isValid: true,
    );
    await _db.insert(record);
    await refresh();
    return record;
  }

  // ------------------------------------------------------------ export/clear

  /// Exports every record (not just the loaded page) to CSV and opens the
  /// share sheet. Ignored while another export is running.
  Future<ExportResult> exportCsv({bool ignoreLowStorage = false}) async {
    if (_isExporting) {
      return ExportResult(
        outcome: ExportOutcome.failed,
        error: StateError('An export is already running'),
      );
    }
    _isExporting = true;
    notifyListeners();
    try {
      final result = await _exporter.export(ignoreLowStorage: ignoreLowStorage);
      if (result.outcome == ExportOutcome.success) {
        try {
          await _tracker.markExported(DateTime.now());
        } catch (e) {
          debugPrint('Could not record the export time: $e');
        }
      }
      return result;
    } finally {
      _isExporting = false;
      notifyListeners();
    }
  }

  /// All rows, ignoring the current search.
  Future<int> freshTotalCount() => _db.count();

  Future<bool> shouldWarnNotExported() async {
    try {
      return await _tracker.needsExportWarning(_db);
    } catch (e) {
      debugPrint('Export warning check failed: $e');
      return false;
    }
  }

  /// Deletes every record. True on success; false (state untouched) when the
  /// delete failed. Ignored while a clear is already running.
  Future<bool> clearAllRecords() async {
    if (_isClearing) return false;
    _isClearing = true;
    notifyListeners();
    try {
      await clearAll();
      return true;
    } catch (e, st) {
      debugPrint('Clearing records failed: $e\n$st');
      return false;
    } finally {
      _isClearing = false;
      notifyListeners();
    }
  }

  Future<void> _reload({required bool showLoading}) async {
    final generation = ++_generation;
    final query = _searchQuery;
    _isLoadingMore = false;
    if (showLoading) _isLoading = true;
    notifyListeners();

    try {
      final results = await Future.wait<Object?>([
        _db.getPage(batchQuery: query),
        _db.count(batchQuery: query),
        _db.count(),
        _db.latestScanTimestamp(),
      ]);
      if (generation != _generation) return;

      final page = results[0]! as List<ScanRecord>;
      _records = page;
      _matchCount = results[1]! as int;
      _totalCount = results[2]! as int;
      _lastScanAt = results[3] as DateTime?;
      _hasMore = page.length == kHistoryPageSize;
      _loadedQuery = query;
      _error = null;
    } catch (e, st) {
      // Keep whatever was already on screen.
      debugPrint('HistoryProvider reload failed: $e\n$st');
      if (generation == _generation) _error = e;
    } finally {
      if (generation == _generation) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    super.dispose();
  }
}
