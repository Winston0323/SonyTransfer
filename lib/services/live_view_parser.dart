import 'dart:typed_data';

/// Pulls JPEG frames out of a Sony live-view byte stream.
///
/// The A7 generation (including the A7R III) sends the classic packet layout:
/// an 8-byte common header, a 128-byte payload header beginning with
/// `24 35 68 79`, then the JPEG and a one-byte padding count. Newer bodies
/// sometimes wrap the same JPEG in a little-endian length header instead.
/// Bytes are delivered in arbitrary TCP chunks, so this keeps a remainder
/// until a whole frame is present.
class LiveViewParser {
  Uint8List _data = Uint8List(0);
  int _start = 0;

  static const int _headerLength = 136;
  static const int _maxPayload = 8 * 1024 * 1024;

  List<Uint8List> add(List<int> chunk) {
    if (chunk.isEmpty) return const [];
    final incoming = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    final pending = _data.length - _start;
    final merged = Uint8List(pending + incoming.length);
    if (pending > 0) {
      merged.setRange(0, pending, _data, _start);
    }
    merged.setRange(pending, merged.length, incoming);
    _data = merged;
    _start = 0;

    final frames = <Uint8List>[];
    while (true) {
      final before = _start;
      final step = _pull();
      if (step.needMore) break;
      if (step.jpeg != null) frames.add(step.jpeg!);
      if (_start == before) {
        // A consume path that does not advance would spin forever.
        _start += 1;
      }
    }
    _compact();
    return frames;
  }

  void _compact() {
    if (_start <= 0) return;
    if (_start >= _data.length) {
      _data = Uint8List(0);
      _start = 0;
      return;
    }
    _data = Uint8List.sublistView(_data, _start);
    _start = 0;
  }

  int get _remaining => _data.length - _start;

  int _at(int index) => _data[_start + index];

  int _u24be(int index) =>
      (_at(index) << 16) | (_at(index + 1) << 8) | _at(index + 2);

  int _u32le(int index) =>
      _at(index) |
      (_at(index + 1) << 8) |
      (_at(index + 2) << 16) |
      (_at(index + 3) << 24);

  _Step _pull() {
    if (_remaining < 2) return const _Step.needMore();

    if (_at(0) == 0xFF && (_at(1) == 0x01 || _at(1) == 0x02)) {
      final classic = _pullClassic();
      if (classic != null) return classic;
    }

    if (_at(0) == 0xFF && _at(1) == 0xD8) {
      return _pullRawJpeg();
    }

    if (_at(0) != 0xFF) {
      final modern = _pullModern();
      if (modern != null) return modern;
    }

    return _resync();
  }

  /// Null when these bytes are not a classic packet, so the caller can try
  /// another layout. [ _Step.needMore] when the header matches but the JPEG
  /// has not all arrived yet — that must not be treated as a bad packet, or
  /// a frame split across two socket reads would be thrown away.
  _Step? _pullClassic() {
    if (_remaining < 12) return const _Step.needMore();
    if (_at(8) != 0x24 ||
        _at(9) != 0x35 ||
        _at(10) != 0x68 ||
        _at(11) != 0x79) {
      return null;
    }
    if (_remaining < _headerLength) return const _Step.needMore();

    final size = _u24be(12);
    final padding = _at(15);
    if (size <= 0 || size > _maxPayload) {
      _start += 1;
      return const _Step.done();
    }
    final total = _headerLength + size + padding;
    if (_remaining < total) return const _Step.needMore();

    Uint8List? jpeg;
    if (_at(1) == 0x01) {
      final from = _start + _headerLength;
      final view = Uint8List.sublistView(_data, from, from + size);
      if (view.length >= 2 && view[0] == 0xFF && view[1] == 0xD8) {
        jpeg = Uint8List.fromList(view);
      }
    }
    _start += total;
    return _Step.done(jpeg);
  }

  _Step _pullRawJpeg() {
    final end = _indexOfMarker(0xD9, _start + 2, _data.length);
    if (end < 0) {
      if (_remaining > _maxPayload) {
        _start += 1;
        return const _Step.done();
      }
      return const _Step.needMore();
    }
    final jpeg = Uint8List.fromList(
      Uint8List.sublistView(_data, _start, end + 2),
    );
    _start = end + 2;
    return _Step.done(jpeg);
  }

  _Step? _pullModern() {
    if (_remaining < 8) return null;
    final headerLen = _u32le(0);
    final frameSpan = _u32le(4);
    if (headerLen < 16 ||
        headerLen > 1024 ||
        frameSpan <= 0 ||
        frameSpan > _maxPayload) {
      return null;
    }
    final total = headerLen + frameSpan;
    if (_remaining < total) return const _Step.needMore();

    final frameStart = _start;
    final frameEnd = frameStart + total;
    final jpegAt = _indexOfMarker(0xD8, frameStart + headerLen, frameEnd);
    if (jpegAt < 0) {
      _start += 1;
      return const _Step.done();
    }
    final eoi = _indexOfMarker(0xD9, jpegAt + 2, frameEnd);
    _start = frameEnd;
    if (eoi < 0) return const _Step.done();
    return _Step.done(
      Uint8List.fromList(Uint8List.sublistView(_data, jpegAt, eoi + 2)),
    );
  }

  _Step _resync() {
    for (var i = 1; i < _remaining; i++) {
      if (_at(i) == 0xFF) {
        _start += i;
        return const _Step.done();
      }
    }
    final keep = _remaining > 0 && _at(_remaining - 1) == 0xFF ? 1 : 0;
    _start = _data.length - keep;
    return const _Step.done();
  }

  /// Index of the `0xFF, marker` pair, or -1. The returned index points at
  /// the `0xFF`.
  int _indexOfMarker(int marker, int from, int end) {
    final last = end < _data.length ? end : _data.length;
    for (var i = from; i + 1 < last; i++) {
      if (_data[i] == 0xFF && _data[i + 1] == marker) return i;
    }
    return -1;
  }
}

class _Step {
  const _Step.needMore()
      : needMore = true,
        jpeg = null;

  const _Step.done([this.jpeg]) : needMore = false;

  final bool needMore;
  final Uint8List? jpeg;
}
