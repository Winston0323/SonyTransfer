import 'package:flutter_test/flutter_test.dart';
import 'package:sony_transfer/models/camera_item.dart';
import 'package:sony_transfer/models/timeline.dart';

CameraItem _shot(String name, {DateTime? at, bool raw = false}) => CameraItem(
      id: name,
      title: name,
      folder: '100MSDCF',
      captured: at,
      resources: [
        CameraResource(
          url: 'http://camera/$name',
          byteSize: raw ? null : 1000,
          protocolInfo: 'http-get:*:image/jpeg:*',
        ),
      ],
    );

void main() {
  group('groupIntoTimeline', () {
    test('orders days newest first, and shots newest first within a day', () {
      final sections = groupIntoTimeline([
        _shot('old.JPG', at: DateTime(2026, 7, 28, 9)),
        _shot('newest.JPG', at: DateTime(2026, 7, 30, 18)),
        _shot('earlier_today.JPG', at: DateTime(2026, 7, 30, 8)),
      ]);

      expect(sections.map((s) => s.day),
          [DateTime(2026, 7, 30), DateTime(2026, 7, 28)]);
      expect(
        sections.first.items.map((i) => i.title),
        ['newest.JPG', 'earlier_today.JPG'],
      );
    });

    test('collects undated shots into a trailing section', () {
      final sections = groupIntoTimeline([
        _shot('undated_a.JPG'),
        _shot('dated.JPG', at: DateTime(2026, 7, 30)),
        _shot('undated_b.JPG'),
      ]);

      expect(sections, hasLength(2));
      expect(sections.first.day, isNotNull);
      expect(sections.last.day, isNull);
      // Camera order is preserved, since nothing better is known.
      expect(sections.last.items.map((i) => i.title),
          ['undated_a.JPG', 'undated_b.JPG']);
    });

    test('splits shots that straddle midnight into separate days', () {
      final sections = groupIntoTimeline([
        _shot('before.JPG', at: DateTime(2026, 7, 30, 23, 59)),
        _shot('after.JPG', at: DateTime(2026, 7, 31, 0, 1)),
      ]);

      expect(sections, hasLength(2));
      expect(sections.first.items.single.title, 'after.JPG');
    });

    test('counts only transferable shots per day', () {
      final sections = groupIntoTimeline([
        _shot('a.JPG', at: DateTime(2026, 7, 30, 9)),
        _shot('b.ARW', at: DateTime(2026, 7, 30, 10), raw: true),
      ]);

      expect(sections.single.items, hasLength(2));
      expect(sections.single.transferableCount, 1);
    });

    test('returns nothing for an empty card', () {
      expect(groupIntoTimeline([]), isEmpty);
    });
  });

  group('timelineDayLabel', () {
    final now = DateTime(2026, 7, 31, 14);

    test('names the recent days relatively', () {
      expect(timelineDayLabel(DateTime(2026, 7, 31), now: now), 'Today');
      expect(timelineDayLabel(DateTime(2026, 7, 30), now: now), 'Yesterday');
    });

    test('falls back to a zero-padded date further back', () {
      expect(timelineDayLabel(DateTime(2026, 7, 5), now: now), '2026-07-05');
    });

    test('labels the undated section', () {
      expect(timelineDayLabel(null, now: now), 'No date');
    });
  });
}
