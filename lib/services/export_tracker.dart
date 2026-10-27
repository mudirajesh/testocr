import 'package:shared_preferences/shared_preferences.dart';

import '../utils/constants.dart';
import 'database_service.dart';

/// Remembers when data was last exported, so Clear All can warn about data
/// that has never left the device.
class ExportTracker {
  ExportTracker({Future<SharedPreferences> Function()? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  Future<DateTime?> lastExportAt() async {
    final stored = (await _prefs()).getString(kPrefLastExportAt);
    return stored == null ? null : DateTime.tryParse(stored)?.toLocal();
  }

  /// Called right after the share sheet opened. On Android the share result is
  /// not reliable (it cannot tell "sent" from "closed"), so "opened" is the
  /// best signal available. Clearing records does not reset this.
  Future<void> markExported(DateTime when) async {
    await (await _prefs()).setString(
      kPrefLastExportAt,
      when.toUtc().toIso8601String(),
    );
  }

  /// True when there is data AND (never exported OR a scan is newer than the
  /// last export).
  Future<bool> needsExportWarning(DatabaseService db) async {
    if (await db.count() == 0) return false;
    final last = await lastExportAt();
    if (last == null) return true;
    final latest = await db.latestScanTimestamp();
    return latest != null && latest.isAfter(last);
  }
}
