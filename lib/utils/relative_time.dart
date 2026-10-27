import 'package:intl/intl.dart';

final _absoluteFormat = DateFormat('dd MMM yyyy');

/// Short "time ago" text for the Home "Last Scan" tile.
///
/// < 1 min "Just now"; < 60 min "{n}m ago"; < 24 h "{n}h ago"; yesterday
/// (calendar day) "Yesterday"; < 7 days "{n}d ago"; otherwise "dd MMM yyyy".
/// A timestamp in the future (clock change) is "Just now".
String formatRelativeTime(DateTime now, DateTime then) {
  final elapsed = now.difference(then);
  if (elapsed < const Duration(minutes: 1)) return 'Just now'; // incl. future
  if (elapsed < const Duration(hours: 1)) return '${elapsed.inMinutes}m ago';
  if (elapsed < const Duration(hours: 24)) return '${elapsed.inHours}h ago';

  // Calendar days, computed on UTC dates so daylight saving cannot skew them.
  final today = DateTime.utc(now.year, now.month, now.day);
  final thenDay = DateTime.utc(then.year, then.month, then.day);
  final days = today.difference(thenDay).inDays;

  if (days <= 1) return 'Yesterday';
  if (days < 7) return '${days}d ago';
  return _absoluteFormat.format(then);
}
