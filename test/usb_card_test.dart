import 'package:flutter_test/flutter_test.dart';
import 'package:sony_transfer/models/usb_card.dart';
import 'package:sony_transfer/services/usb_camera.dart';

UsbCard _card({
  required int id,
  required int jpeg,
  required int raw,
  bool suggested = false,
}) =>
    UsbCard(
      id: id,
      label: 'Card ${id + 1}',
      jpegCount: jpeg,
      rawCount: raw,
      hasDcim: jpeg + raw > 0,
      suggested: suggested,
    );

void main() {
  group('suggestedUsbCardId', () {
    test('picks the card with the most JPEGs', () {
      expect(
        suggestedUsbCardId([
          _card(id: 0, jpeg: 2, raw: 100),
          _card(id: 1, jpeg: 80, raw: 0),
        ]),
        1,
      );
    });

    test('on a JPEG tie, prefers fewer RAWs (the Sort RAW/JPEG slot)', () {
      expect(
        suggestedUsbCardId([
          _card(id: 0, jpeg: 10, raw: 50),
          _card(id: 1, jpeg: 10, raw: 0),
        ]),
        1,
      );
    });

    test('ignores cards with no JPEGs', () {
      expect(
        suggestedUsbCardId([
          _card(id: 0, jpeg: 0, raw: 200),
          _card(id: 1, jpeg: 5, raw: 0),
        ]),
        1,
      );
    });

    test('returns null when nothing has JPEGs', () {
      expect(
        suggestedUsbCardId([_card(id: 0, jpeg: 0, raw: 10)]),
        isNull,
      );
    });
  });

  group('UsbCamera url helpers', () {
    test('round-trips card id and path', () {
      final url = UsbCamera.urlFor(1, 'DCIM/100MSDCF/DSC00001.JPG');
      final parsed = UsbCamera.parseUrl(url);
      expect(parsed, isNotNull);
      expect(parsed!.$1, 1);
      expect(parsed.$2, 'DCIM/100MSDCF/DSC00001.JPG');
    });

    test('round-trips a MediaStore content URI path', () {
      const content =
          'content://media/external_1234/images/media/42';
      final parsed = UsbCamera.parseUrl(UsbCamera.urlFor(0, content));
      expect(parsed?.$1, 0);
      expect(parsed?.$2, content);
    });

    test('rejects non-usb urls', () {
      expect(UsbCamera.parseUrl('http://192.168.122.1/x.jpg'), isNull);
    });
  });
}
