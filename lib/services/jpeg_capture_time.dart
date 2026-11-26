/// Reads the capture time stamped in a JPEG's EXIF block.
///
/// Only the first part of the file is required — the EXIF APP1 segment is
/// written before the image data. Returns null when the file has no EXIF
/// date rather than guessing.
DateTime? jpegCaptureTime(List<int> bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var i = 2;
  while (i + 4 <= bytes.length) {
    if (bytes[i] != 0xFF) return null;
    final marker = bytes[i + 1];
    // Standalone markers (no length): restart markers and TEM.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) return null;
    final size = (bytes[i + 2] << 8) | bytes[i + 3];
    if (size < 2 || i + 2 + size > bytes.length) return null;
    if (marker == 0xE1) {
      final date = _dateFromExif(bytes, i + 4, i + 2 + size);
      if (date != null) return date;
    }
    i += 2 + size;
  }
  return null;
}

/// `YYYY:MM:DD HH:MM:SS` as written by Sony, interpreted as local time.
DateTime? parseExifDate(String text) {
  final match = RegExp(
    r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(text.trim());
  if (match == null) return null;
  final parts = [
    for (var i = 1; i <= 6; i++) int.parse(match.group(i)!),
  ];
  final date = DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
  if (date.year < 1980 || date.month != parts[1] || date.day != parts[2]) {
    return null;
  }
  return date;
}

DateTime? _dateFromExif(List<int> bytes, int start, int end) {
  const signature = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // Exif\0\0
  if (end - start < signature.length + 8) return null;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[start + i] != signature[i]) return null;
  }
  final tiff = start + signature.length;
  final little = bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49;
  final big = bytes[tiff] == 0x4D && bytes[tiff + 1] == 0x4D;
  if (!little && !big) return null;

  int u16(int offset) {
    if (offset < 0 || offset + 1 >= end) return 0;
    return little
        ? bytes[offset] | (bytes[offset + 1] << 8)
        : (bytes[offset] << 8) | bytes[offset + 1];
  }

  int u32(int offset) {
    if (offset < 0 || offset + 3 >= end) return 0;
    return little
        ? bytes[offset] |
            (bytes[offset + 1] << 8) |
            (bytes[offset + 2] << 16) |
            (bytes[offset + 3] << 24)
        : (bytes[offset] << 24) |
            (bytes[offset + 1] << 16) |
            (bytes[offset + 2] << 8) |
            bytes[offset + 3];
  }

  DateTime? walk(int ifd, {required bool allowSub}) {
    if (ifd < tiff || ifd + 2 > end) return null;
    final count = u16(ifd);
    if (count <= 0 || count > 256) return null;
    DateTime? original;
    DateTime? fallback;
    int? subIfd;
    for (var entry = 0; entry < count; entry++) {
      final at = ifd + 2 + entry * 12;
      if (at + 12 > end) break;
      final tag = u16(at);
      final type = u16(at + 2);
      final values = u32(at + 4);
      if (tag == 0x8769 && allowSub) {
        final pointer = u32(at + 8);
        if (pointer > 0) subIfd = tiff + pointer;
        continue;
      }
      if (type != 2 || values < 10 || values > 64) continue;
      if (tag != 0x9003 && tag != 0x9004 && tag != 0x0132) continue;
      final dataAt = values <= 4 ? at + 8 : tiff + u32(at + 8);
      if (dataAt < tiff || dataAt + values > end) continue;
      final text = String.fromCharCodes(
        bytes.sublist(dataAt, dataAt + values).where((b) => b != 0),
      );
      final parsed = parseExifDate(text);
      if (parsed == null) continue;
      if (tag == 0x9003) {
        original = parsed;
      } else {
        fallback ??= parsed;
      }
    }
    return original ?? fallback ?? (subIfd == null ? null : walk(subIfd, allowSub: false));
  }

  final ifd0 = tiff + u32(tiff + 4);
  return walk(ifd0, allowSub: true);
}
