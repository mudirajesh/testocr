// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scan_record.dart';
import '../utils/constants.dart';
import '../utils/csv_text.dart';
import 'database_service.dart';

/// Above this many rows the CSV is built on a background isolate.
const _computeThreshold = 2000;

// ---------------------------------------------------------------------------
// Pure builder

final _scanTimeFormat = DateFormat('dd/MM/yyyy HH:mm:ss');

/// Builds the export text: header row plus one row per record, in the order
/// given (callers pass newest first). CRLF line endings, standard quoting.
String buildCsv(
  List<ScanRecord> records, {
  bool protectLeadingZeros = kCsvProtectLeadingZeros,
}) {
  final rows = <List<Object?>>[
    List<Object?>.from(kCsvHeaders),
    for (var i = 0; i < records.length; i++)
      _row(i + 1, records[i], protectLeadingZeros),
  ];
  return Csv(lineDelimiter: '\r\n').encode(rows);
}

List<Object?> _row(int number, ScanRecord r, bool protect) {
  return [
    number, // Sr. No. is a plain number, not text
    _text(r.batchNumber),
    _text(r.gtin, protectDigits: protect),
    _text(_expiry(r)),
    _text(r.serialNumber, protectDigits: protect),
    // The GS control character is shown as text, in the export only.
    _text(r.rawBarcode.replaceAll('\u001D', '<GS>')),
    _text(r.barcodeFormat),
    _text(_scanTimeFormat.format(r.scanTimestamp)),
    r.isValid ? 'Yes' : 'No',
    _text(r.confidencePercent),
  ];
}

/// Display expiry, or the raw YYMMDD when it is present but not a real date.
String? _expiry(ScanRecord r) => r.expiryDisplay ?? r.expiryDate;

String _text(String? value, {bool protectDigits = false}) =>
    csvSafeText(value, protectDigits: protectDigits);

/// compute() needs a one-argument top-level function.
String _buildCsvDefault(List<ScanRecord> records) => buildCsv(records);

// ---------------------------------------------------------------------------
// IO

enum ExportOutcome { success, empty, lowStorage, failed }

class ExportResult {
  const ExportResult({
    required this.outcome,
    this.path,
    this.rowCount = 0,
    this.error,
  });

  final ExportOutcome outcome;
  final String? path;
  final int rowCount;
  final Object? error;
}

Future<void> _defaultShare(File file) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: 'text/csv')],
      subject: 'GS1 Scan export',
    ),
  );
}

Future<int?> _defaultFreeBytes() async {
  final megabytes = await DiskSpacePlus().getFreeDiskSpace;
  return megabytes == null ? null : (megabytes * 1024 * 1024).round();
}

/// Writes the history to a CSV file in the temp folder and hands it to the
/// system share sheet. Never throws: problems come back in [ExportResult].
class CsvExportService {
  CsvExportService({
    required DatabaseService db,
    Future<Directory> Function()? tempDir,
    Future<void> Function(File file)? share,
    Future<int?> Function()? freeBytes,
    DateTime Function()? now,
  }) : _db = db,
       _tempDir = tempDir ?? getTemporaryDirectory,
       _share = share ?? _defaultShare,
       _freeBytes = freeBytes ?? _defaultFreeBytes,
       _now = now ?? DateTime.now;

  final DatabaseService _db;
  final Future<Directory> Function() _tempDir;
  final Future<void> Function(File file) _share;
  final Future<int?> Function() _freeBytes;
  final DateTime Function() _now;

  static final _stampFormat = DateFormat('yyyyMMdd_HHmmss');

  Future<ExportResult> export({bool ignoreLowStorage = false}) async {
    try {
      final count = await _db.count();
      if (count == 0) return const ExportResult(outcome: ExportOutcome.empty);

      if (!ignoreLowStorage && await _isLowOnStorage()) {
        return const ExportResult(outcome: ExportOutcome.lowStorage);
      }

      final records = await _db.getAll();
      final text = records.length > _computeThreshold
          ? await compute(_buildCsvDefault, records)
          : buildCsv(records);

      final dir = await _tempDir();
      final name = '$kCsvFilePrefix${_stampFormat.format(_now())}.csv';
      final file = File(p.join(dir.path, name));
      // UTF-8 BOM first so Excel reads non-ASCII text (e.g. Hindi) correctly.
      await file.writeAsBytes([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(text),
      ], flush: true);

      await _share(file);
      return ExportResult(
        outcome: ExportOutcome.success,
        path: file.path,
        rowCount: records.length,
      );
    } catch (e, st) {
      debugPrint('CSV export failed: $e\n$st');
      return ExportResult(outcome: ExportOutcome.failed, error: e);
    }
  }

  /// A failing or unavailable check is skipped silently.
  Future<bool> _isLowOnStorage() async {
    try {
      final free = await _freeBytes();
      return free != null && free < kCsvMinFreeBytes;
    } catch (_) {
      return false;
    }
  }

  /// Deletes old export files; scan data should not linger in the cache.
  Future<void> cleanupOldExports({
    Duration olderThan = const Duration(days: 1),
  }) async {
    try {
      final dir = await _tempDir();
      if (!await dir.exists()) return;
      final cutoff = _now().subtract(olderThan);
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith(kCsvFilePrefix) || !name.endsWith('.csv')) {
          continue;
        }
        if ((await entity.lastModified()).isBefore(cutoff)) {
          await entity.delete();
        }
      }
    } catch (e) {
      debugPrint('Export cleanup failed: $e');
    }
  }
}
