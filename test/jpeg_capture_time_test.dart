import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sony_transfer/services/jpeg_capture_time.dart';

/// A tiny JPEG whose EXIF DateTimeOriginal is [date].
Uint8List _jpegWithDate(String date) {
  final text = Uint8List.fromList('$date\x00'.codeUnits);
  expect(text.length, 20);

  final tiff = BytesBuilder();
  void u16(int value) {
    tiff.addByte(value & 0xFF);
    tiff.addByte((value >> 8) & 0xFF);
  }

  void u32(int value) {
    tiff.addByte(value & 0xFF);
    tiff.addByte((value >> 8) & 0xFF);
    tiff.addByte((value >> 16) & 0xFF);
    tiff.addByte((value >> 24) & 0xFF);
  }

  // TIFF header, IFD0 with a pointer to the Exif IFD, then DateTimeOriginal.
  tiff
    ..addByte(0x49)
    ..addByte(0x49);
  u16(42);
  u32(8);
  u16(1);
  u16(0x8769);
  u16(4);
  u32(1);
  u32(26);
  u32(0);
  u16(1);
  u16(0x9003);
  u16(2);
  u32(20);
  u32(44);
  u32(0);
  tiff.add(text);

  final payload = BytesBuilder()
    ..add('Exif\x00\x00'.codeUnits)
    ..add(tiff.toBytes());
  final bytes = payload.toBytes();
  final size = bytes.length + 2;
  return Uint8List.fromList([
    0xFF,
    0xD8,
    0xFF,
    0xE1,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...bytes,
  ]);
}

void main() {
  test('reads DateTimeOriginal from the Exif IFD', () {
    final when = jpegCaptureTime(_jpegWithDate('2026:11:06 23:17:08'));
    expect(when, DateTime(2026, 11, 6, 23, 17, 8));
  });

  test('a JPEG with no EXIF has no capture time', () {
    expect(
      jpegCaptureTime(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])),
      isNull,
    );
  });
}
