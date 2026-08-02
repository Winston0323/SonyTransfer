import 'dart:io';

import 'package:path/path.dart' as p;

/// A shot already sitting in the app's local download cache from a previous
/// transfer — the source for the album home page.
class TransferredPhoto {
  const TransferredPhoto({required this.file, required this.takenAt});

  final File file;

  /// When the shot was taken. The transfer stamps each downloaded file's
  /// modification time with the capture date the camera reported, so this
  /// survives without a separate database. Files whose shot had no date —
  /// or that were transferred before the app started stamping — carry the
  /// time they were downloaded instead.
  final DateTime takenAt;

  String get id => file.path;

  String get fileName => p.basename(file.path);
}

/// One day's worth of already-transferred shots.
class TransferredDaySection {
  const TransferredDaySection({required this.day, required this.photos});

  final DateTime day;
  final List<TransferredPhoto> photos;
}

/// Groups already-transferred shots by the day they were taken, newest
/// first, newest within each day — the same shape as the camera's own
/// timeline, so the album feels consistent with it.
List<TransferredDaySection> groupTransferredByDay(
  List<TransferredPhoto> photos,
) {
  final byDay = <DateTime, List<TransferredPhoto>>{};
  for (final photo in photos) {
    final at = photo.takenAt;
    final day = DateTime(at.year, at.month, at.day);
    byDay.putIfAbsent(day, () => []).add(photo);
  }

  final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final day in days)
      TransferredDaySection(
        day: day,
        photos: byDay[day]!..sort((a, b) => b.takenAt.compareTo(a.takenAt)),
      ),
  ];
}
