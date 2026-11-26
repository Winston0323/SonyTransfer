import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'usb_camera.dart';

/// Caches camera-served thumbnails and previews on disk, and caps how many
/// are fetched from the camera at once.
///
/// The camera's embedded web server is not built for a phone asking for a
/// dozen thumbnails at once while the grid scrolls fast — requests just queue
/// up on its side, and whichever one lands last can take several seconds even
/// though the file itself is tiny. Capping concurrency here keeps each
/// individual fetch quick. Caching to disk means a shot scrolled past once
/// never costs another camera round trip, even after reconnecting later.
class ThumbnailCache {
  ThumbnailCache._();

  static final ThumbnailCache instance = ThumbnailCache._();

  static const int _maxConcurrent = 4;

  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  final http.Client _client = http.Client();

  /// Keyed by URL so a shot rebuilt mid-fetch (selection changes, scrolling
  /// back and forth) shares the one download already underway instead of
  /// starting another.
  final Map<String, Future<File>> _pending = {};

  Directory? _cacheDir;

  Future<Directory> _dir() async {
    final existing = _cacheDir;
    if (existing != null) return existing;
    // dart:io's own temp dir rather than package:path_provider: Flutter's
    // Android embedding already points TMPDIR at the app's cache directory,
    // and this avoids a platform-channel round trip for every cold start.
    final dir = Directory(p.join(Directory.systemTemp.path, 'camera_thumbs'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _cacheDir = dir;
  }

  /// A local file holding [url]'s bytes, downloading and caching it first if
  /// this is the first time it has been asked for.
  ///
  /// [fullQuality] only affects `usb:` URLs: the grid uses device thumbnails,
  /// while the full-screen preview copies the real JPEG.
  Future<File> fileFor(String url, {bool fullQuality = false}) {
    final key = fullQuality ? 'full:$url' : url;
    return _pending.putIfAbsent(key, () => _load(url, fullQuality: fullQuality));
  }

  Future<File> _load(String url, {bool fullQuality = false}) async {
    final pendingKey = fullQuality ? 'full:$url' : url;
    var acquired = false;
    try {
      final dir = await _dir();
      final file = File(
        p.join(dir.path, _fileNameFor(url, fullQuality: fullQuality)),
      );
      if (await file.exists() && await file.length() > 0) return file;

      await _acquireSlot();
      acquired = true;

      if (url.startsWith('usb:')) {
        final parsed = UsbCamera.parseUrl(url);
        if (parsed == null) throw StateError('bad usb url');
        if (fullQuality) {
          await UsbCamera.copyJpeg(
            cardId: parsed.$1,
            usbPath: parsed.$2,
            destPath: file.path,
          );
          if (!await file.exists() || await file.length() <= 0) {
            throw StateError('usb copy failed for $url');
          }
          return file;
        }
        final bytes = await UsbCamera.loadThumb(
          cardId: parsed.$1,
          usbPath: parsed.$2,
        );
        if (bytes == null || bytes.isEmpty) {
          throw StateError('no thumb for $url');
        }
        await file.writeAsBytes(bytes, flush: true);
        return file;
      }

      final response = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode} for $url');
      }
      await file.writeAsBytes(response.bodyBytes, flush: true);
      return file;
    } catch (_) {
      // Do not remember a failure as a permanent result; the next request
      // for this URL should get a fresh try rather than repeating the error.
      _pending.remove(pendingKey);
      rethrow;
    } finally {
      if (acquired) _releaseSlot();
    }
  }

  Future<void> _acquireSlot() {
    if (_active < _maxConcurrent) {
      _active++;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    return completer.future.then((_) => _active++);
  }

  void _releaseSlot() {
    _active--;
    if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
  }

  /// Deterministic, filesystem-safe cache key for [url] (Jenkins one-at-a-time
  /// hash — no need to pull in a crypto package for this).
  String _fileNameFor(String url, {bool fullQuality = false}) {
    var hash = 0;
    for (final unit in url.codeUnits) {
      hash = 0x1fffffff & (hash + unit);
      hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
      hash ^= hash >> 6;
    }
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash ^= hash >> 11;
    hash = 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
    // USB thumbs/full copies are JPEG bytes from the platform side; content://
    // paths have no useful image extension.
    if (url.startsWith('usb:')) {
      return fullQuality ? '$hash.full.jpg' : '$hash.jpg';
    }
    final ext = p.extension(Uri.parse(url).path);
    return '$hash${ext.isEmpty ? '.jpg' : ext}';
  }
}
