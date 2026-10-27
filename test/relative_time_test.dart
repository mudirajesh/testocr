import 'package:flutter_test/flutter_test.dart';
import 'package:gs1scan/utils/relative_time.dart';

void main() {
  final now = DateTime(2026, 9, 29, 14, 30, 0);

  String at(Duration ago) => formatRelativeTime(now, now.subtract(ago));

  group('formatRelativeTime', () {
    test('under a minute is Just now', () {
      expect(at(Duration.zero), 'Just now');
      expect(at(const Duration(seconds: 59)), 'Just now');
    });

    test('minutes', () {
      expect(at(const Duration(minutes: 1)), '1m ago');
      expect(at(const Duration(minutes: 59, seconds: 59)), '59m ago');
    });

    test('hours', () {
      expect(at(const Duration(hours: 1)), '1h ago');
      expect(at(const Duration(hours: 2, minutes: 30)), '2h ago');
      expect(at(const Duration(hours: 23, minutes: 59)), '23h ago');
    });

    test('yesterday across midnight', () {
      // 40 minutes ago, but on the previous calendar day: still minutes.
      final justAfterMidnight = DateTime(2026, 9, 29, 0, 30);
      expect(
        formatRelativeTime(justAfterMidnight, DateTime(2026, 9, 28, 23, 50)),
        '40m ago',
      );
      // More than 24h ago and on the previous calendar day.
      expect(
        formatRelativeTime(
          DateTime(2026, 9, 29, 23, 0),
          DateTime(2026, 9, 28, 0, 10),
        ),
        'Yesterday',
      );
      expect(at(const Duration(hours: 25)), 'Yesterday');
    });

    test('days under a week', () {
      expect(at(const Duration(days: 2)), '2d ago');
      expect(at(const Duration(days: 6, hours: 1)), '6d ago');
      // Calendar days, not 24h blocks: 26h ago but two dates back.
      expect(
        formatRelativeTime(
          DateTime(2026, 9, 29, 1, 0),
          DateTime(2026, 9, 27, 23, 0),
        ),
        '2d ago',
      );
    });

    test('a week or more shows the date', () {
      expect(at(const Duration(days: 7)), '22 Sep 2026');
      expect(
        formatRelativeTime(now, DateTime(2025, 1, 5, 9, 0)),
        '05 Jan 2025',
      );
    });

    test('a future timestamp is Just now', () {
      expect(
        formatRelativeTime(now, now.add(const Duration(hours: 3))),
        'Just now',
      );
      expect(
        formatRelativeTime(now, now.add(const Duration(days: 40))),
        'Just now',
      );
    });

    test('is not thrown off by daylight saving changes', () {
      // 25 hours of wall clock across a DST boundary is still "Yesterday".
      expect(
        formatRelativeTime(DateTime(2026, 3, 30, 12), DateTime(2026, 3, 29, 9)),
        'Yesterday',
      );
    });
  });
}
