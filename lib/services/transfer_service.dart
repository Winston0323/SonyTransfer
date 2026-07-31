import 'dart:async';
import 'dart:io';

import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/camera_item.dart';

enum TransferOutcome { saved, skippedExisting, skippedRaw, failed }

class TransferProgress {
  const TransferProgress({
    required this.item,
    required this.received,
    required this.total,
    required this.bytesPerSecond,
  });

  final CameraItem item;
  final int received;
  final int total;
  final double bytesPerSecond;
}

class TransferResult {
  const TransferResult(this.item, this.outcome, {this.detail});

  final CameraItem item;
  final TransferOutcome outcome;
  final String? detail;
}

/// Downloads shots off the camera and files them into the phone's gallery.
class TransferService {
  TransferService({
    http.Client? client,
    this.albumName = 'SonyTransfer',
    Directory? destination,
    Future<void> Function(File file)? saveToGallery,
  })  : _client = client ?? http.Client(),
        _destination = destination,
        _saveToGallery = saveToGallery;

  /// Overrides for tests, which have no platform channels to ask for the
  /// external storage path or to reach the gallery.
  final Directory? _destination;
  final Future<void> Function(File file)? _saveToGallery;

  final http.Client _client;
  final String albumName;

  /// Progress is throttled to this interval. At a few MB/s the chunk callback
  /// fires hundreds of times a second, and repainting that often steals time
  /// from the download itself — both run on the one Dart isolate.
  static const Duration _progressInterval = Duration(milliseconds: 200);

  final Stopwatch _clock = Stopwatch();
  int _sessionBytes = 0;
  int _lastEmitMs = 0;

  bool _cancelled = false;

  /// Throughput over the current batch, which distinguishes a slow link from a
  /// slow app.
  double get averageBytesPerSecond {
    final seconds = _clock.elapsedMicroseconds / 1000000;
    return seconds <= 0 ? 0 : _sessionBytes / seconds;
  }

  void cancel() => _cancelled = true;
  void resetCancel() => _cancelled = false;
  bool get isCancelled => _cancelled;

  void close() => _client.close();

  Future<Directory> destinationDirectory() async {
    final override = _destination;
    if (override != null) {
      if (!await override.exists()) await override.create(recursive: true);
      return override;
    }
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, albumName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Transfers [items] one at a time, reporting each result as it lands.
  ///
  /// [onProgress] reports the shot currently in flight, throttled to
  /// [_progressInterval] so the UI cannot starve the download.
  Stream<TransferResult> transferAll(
    List<CameraItem> items, {
    void Function(TransferProgress progress)? onProgress,
  }) async* {
    final dir = await destinationDirectory();
    _sessionBytes = 0;
    _lastEmitMs = 0;
    _clock
      ..reset()
      ..start();

    for (final item in items) {
      if (_cancelled) return;

      if (item.isRawOnly) {
        yield TransferResult(
          item,
          TransferOutcome.skippedRaw,
          detail: 'raw only — camera serves no full-size JPEG',
        );
        continue;
      }

      final resource = item.original!;
      final file = File(p.join(dir.path, item.fileName));

      if (await file.exists() &&
          resource.byteSize != null &&
          await file.length() == resource.byteSize) {
        yield TransferResult(item, TransferOutcome.skippedExisting);
        continue;
      }

      try {
        await _download(item, resource, file, onProgress);
        await _addToGallery(file);
        yield TransferResult(item, TransferOutcome.saved);
      } catch (e) {
        if (await file.exists()) await file.delete();
        yield TransferResult(item, TransferOutcome.failed, detail: '$e');
      }
    }
  }

  void _emitProgress(
    CameraItem item,
    int received,
    int total,
    void Function(TransferProgress progress)? onProgress, {
    bool force = false,
  }) {
    if (onProgress == null) return;

    final elapsedMs = _clock.elapsedMilliseconds;
    final finished = total > 0 && received >= total;
    if (!force &&
        !finished &&
        elapsedMs - _lastEmitMs < _progressInterval.inMilliseconds) {
      return;
    }
    _lastEmitMs = elapsedMs;

    onProgress(
      TransferProgress(
        item: item,
        received: received,
        total: total,
        bytesPerSecond: averageBytesPerSecond,
      ),
    );
  }

  Future<void> _download(
    CameraItem item,
    CameraResource resource,
    File file,
    void Function(TransferProgress progress)? onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(resource.url));
    final response = await _client.send(request);

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final total = response.contentLength ?? resource.byteSize ?? 0;

    // Announce the new shot at zero bytes rather than waiting for its first
    // chunk, which on this link can be most of a second away — long enough for a
    // per-shot progress bar to sit at the previous shot's 100%.
    _emitProgress(item, 0, total, onProgress, force: true);

    // Download to a temporary name so an interrupted transfer never leaves a
    // half-written file that the skip-existing check might later trust.
    final partial = File('${file.path}.part');
    final sink = partial.openWrite();
    var received = 0;

    try {
      await for (final chunk in response.stream) {
        if (_cancelled) throw Exception('cancelled');
        sink.add(chunk);
        received += chunk.length;
        _sessionBytes += chunk.length;
        _emitProgress(item, received, total, onProgress);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (total > 0 && received != total) {
      await partial.delete();
      throw Exception('truncated: got $received of $total bytes');
    }

    await partial.rename(file.path);
  }

  Future<void> _addToGallery(File file) async {
    final custom = _saveToGallery;
    if (custom != null) return custom(file);

    if (!await Gal.hasAccess()) {
      await Gal.requestAccess();
    }
    await Gal.putImage(file.path, album: albumName);
  }
}
