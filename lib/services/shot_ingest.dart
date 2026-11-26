import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'jpeg_capture_time.dart';
import 'scalar_camera.dart';
import 'transfer_service.dart';

String fileNameFromCameraUrl(Uri url) {
  final raw = url.pathSegments.isEmpty ? '' : url.pathSegments.last;
  final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'shot.jpg';
  final lower = cleaned.toLowerCase();
  if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg')) {
    return '$cleaned.jpg';
  }
  return cleaned;
}

/// Downloads one shutter JPEG into the same cache the album already lists.
class ShotIngest {
  ShotIngest(this._transfer, {http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final TransferService _transfer;
  final http.Client _client;
  final bool _ownsClient;

  void close() {
    if (_ownsClient) _client.close();
  }

  /// Returns the file name written into the album cache.
  Future<String> save(Uri url) async {
    if (!isShotUrl(url.toString())) {
      throw ScalarException('Camera did not return a JPEG address.');
    }
    final dir = await _transfer.destinationDirectory();
    final name = await _freshName(dir, fileNameFromCameraUrl(url));
    final dest = File(p.join(dir.path, name));
    final part = File('${dest.path}.part');
    final header = <int>[];

    try {
      final response = await _client
          .send(http.Request('GET', url))
          .timeout(const Duration(minutes: 3));
      if (response.statusCode != 200) {
        throw ScalarException(
          'Camera returned HTTP ${response.statusCode} for $name.',
        );
      }
      final sink = part.openWrite();
      try {
        await for (final chunk in response.stream) {
          if (header.length < 65536) {
            final room = 65536 - header.length;
            header.addAll(chunk.length <= room ? chunk : chunk.sublist(0, room));
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      if (await dest.exists()) await dest.delete();
      await part.rename(dest.path);
    } catch (e) {
      if (await part.exists()) {
        try {
          await part.delete();
        } on FileSystemException {
          // The failed partial is useless either way.
        }
      }
      if (e is ScalarException) rethrow;
      throw ScalarException('Could not copy $name ($e).');
    }

    final taken = jpegCaptureTime(header);
    try {
      await _transfer.commitTransferredFile(dest, takenAt: taken);
    } on Object {
      // The cache file is already in place, so the in-app album can show
      // the shot even when the Photos copy is refused.
      rethrow;
    }
    return name;
  }

  Future<String> _freshName(Directory dir, String preferred) async {
    final dot = preferred.lastIndexOf('.');
    final stem = dot <= 0 ? preferred : preferred.substring(0, dot);
    final ext = dot <= 0 ? '' : preferred.substring(dot);
    var name = preferred;
    var n = 2;
    while (await File(p.join(dir.path, name)).exists()) {
      name = '$stem-$n$ext';
      n++;
      if (n > 9999) break;
    }
    return name;
  }
}
