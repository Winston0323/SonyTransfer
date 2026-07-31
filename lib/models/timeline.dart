import 'camera_item.dart';

/// One day's worth of shots in the timeline.
class TimelineSection {
  const TimelineSection({required this.day, required this.items});

  /// Null for shots the camera reported no capture date for.
  final DateTime? day;

  final List<CameraItem> items;

  int get transferableCount => items.where((i) => !i.isRawOnly).length;
}

/// Groups shots into days, newest first, newest within each day.
///
/// Shots with no capture date keep the order the camera listed them in and are
/// collected into a trailing undated section, since there is no defensible place
/// to interleave them.
List<TimelineSection> groupIntoTimeline(List<CameraItem> items) {
  final byDay = <DateTime, List<CameraItem>>{};
  final undated = <CameraItem>[];

  for (final item in items) {
    final captured = item.captured;
    if (captured == null) {
      undated.add(item);
      continue;
    }
    final day = DateTime(captured.year, captured.month, captured.day);
    byDay.putIfAbsent(day, () => []).add(item);
  }

  final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));

  final sections = [
    for (final day in days)
      TimelineSection(
        day: day,
        items: byDay[day]!
          ..sort((a, b) => b.captured!.compareTo(a.captured!)),
      ),
  ];

  if (undated.isNotEmpty) {
    sections.add(TimelineSection(day: null, items: undated));
  }
  return sections;
}

/// Day label for a section header, relative to [now] where that reads better.
String timelineDayLabel(DateTime? day, {DateTime? now}) {
  if (day == null) return 'No date';

  final today = now ?? DateTime.now();
  final startOfToday = DateTime(today.year, today.month, today.day);
  final difference = startOfToday.difference(day).inDays;

  if (difference == 0) return 'Today';
  if (difference == 1) return 'Yesterday';

  final month = day.month.toString().padLeft(2, '0');
  final dayOfMonth = day.day.toString().padLeft(2, '0');
  return '${day.year}-$month-$dayOfMonth';
}
