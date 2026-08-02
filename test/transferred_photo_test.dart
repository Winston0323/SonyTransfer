import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sony_transfer/models/transferred_photo.dart';

TransferredPhoto _photo(String name, DateTime takenAt) =>
    TransferredPhoto(file: File(name), takenAt: takenAt);

void main() {
  group('groupTransferredByDay', () {
    test('orders days newest first, and shots newest first within a day', () {
      final sections = groupTransferredByDay([
        _photo('old.JPG', DateTime(2026, 7, 28, 9)),
        _photo('newest.JPG', DateTime(2026, 7, 30, 18)),
        _photo('earlier_today.JPG', DateTime(2026, 7, 30, 8)),
      ]);

      expect(
        sections.map((s) => s.day),
        [DateTime(2026, 7, 30), DateTime(2026, 7, 28)],
      );
      expect(
        sections.first.photos.map((p) => p.fileName),
        ['newest.JPG', 'earlier_today.JPG'],
      );
    });

    test('splits shots that straddle midnight into separate days', () {
      final sections = groupTransferredByDay([
        _photo('before.JPG', DateTime(2026, 7, 30, 23, 59)),
        _photo('after.JPG', DateTime(2026, 7, 31, 0, 1)),
      ]);

      expect(sections, hasLength(2));
      expect(sections.first.photos.single.fileName, 'after.JPG');
    });

    test('returns nothing for an empty album', () {
      expect(groupTransferredByDay([]), isEmpty);
    });
  });
}
