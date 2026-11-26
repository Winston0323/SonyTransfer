import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sony_transfer/services/live_view_parser.dart';

Uint8List _jpeg() => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);

Uint8List _classic(
  Uint8List jpeg, {
  int type = 0x01,
  int sequence = 1,
  int padding = 0,
}) {
  final packet = Uint8List(136 + jpeg.length + padding);
  packet[0] = 0xFF;
  packet[1] = type;
  packet[2] = (sequence >> 8) & 0xFF;
  packet[3] = sequence & 0xFF;
  packet[8] = 0x24;
  packet[9] = 0x35;
  packet[10] = 0x68;
  packet[11] = 0x79;
  packet[12] = (jpeg.length >> 16) & 0xFF;
  packet[13] = (jpeg.length >> 8) & 0xFF;
  packet[14] = jpeg.length & 0xFF;
  packet[15] = padding;
  packet.setRange(136, 136 + jpeg.length, jpeg);
  return packet;
}

Uint8List _modern(Uint8List jpeg, {int headerLen = 32, int trailer = 4}) {
  final span = jpeg.length + trailer;
  final packet = Uint8List(headerLen + span);
  void le(int offset, int value) {
    packet[offset] = value & 0xFF;
    packet[offset + 1] = (value >> 8) & 0xFF;
    packet[offset + 2] = (value >> 16) & 0xFF;
    packet[offset + 3] = (value >> 24) & 0xFF;
  }

  le(0, headerLen);
  le(4, span);
  packet.setRange(headerLen, headerLen + jpeg.length, jpeg);
  return packet;
}

void main() {
  test('extracts a JPEG split across two socket reads', () {
    final jpeg = _jpeg();
    final packet = _classic(jpeg, sequence: 7);
    final parser = LiveViewParser();

    expect(parser.add(packet.sublist(0, 10)), isEmpty);

    final frames = parser.add(packet.sublist(10));
    expect(frames, hasLength(1));
    expect(frames.single, jpeg);
  });

  test('skips a frame-info packet and the padding after a JPEG', () {
    final jpeg = _jpeg();
    final info = _classic(
      Uint8List(16),
      type: 0x02,
      sequence: 1,
    );
    final image = _classic(jpeg, sequence: 2, padding: 4);
    final parser = LiveViewParser();

    final frames = parser.add([...info, ...image]);
    expect(frames, [jpeg]);
  });

  test('resyncs after leading garbage', () {
    final jpeg = _jpeg();
    final parser = LiveViewParser();
    final frames = parser.add([0x00, 0x11, ..._classic(jpeg)]);
    expect(frames.single, jpeg);
  });

  test('reads a bare JPEG and a modern framed JPEG', () {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x02, 0xFF, 0xD9]);
    final parser = LiveViewParser();
    expect(parser.add(jpeg).single, jpeg);

    final modern = LiveViewParser();
    expect(modern.add(_modern(jpeg)).single, jpeg);
  });
}
