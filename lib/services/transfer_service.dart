import 'dart:async';
import 'dart:io';

import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/camera_item.dart';
import '../models/transferred_photo.dart';
import 'destination_folder.dart';

enum TransferOutcome { saved, skippedExisting, skippedRaw, failed }

class TransferProgress {
  const TransferProgress({
    required this.item,
    required this.position,
    required this.received,
    required this.total,
    required this.bytesPerSecond,
  });

  final CameraItem item;

  /// 1-based place of [item] within the batch being transferred, so the UI
  /// can say "shot 3 of 4 is coming down" rather than "2 are finished" —
  /// the latter reads one behind while a download is in flight.
  final int position;

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

  /// Shots already sitting in the local download cache from a previous
  /// transfer, most recently taken first (each file's modification time is
  /// stamped with the camera's capture date as it is downloaded).
  ///
  /// [destinationDirectory] is private to the app — nothing else ever writes
  /// to it, and a completed download is left there even after also being
  /// copied into the Photos album or a chosen destination folder (see
  /// [_addToGallery]) — so everything found here was necessarily transferred
  /// by this app, unlike either of those, which may already hold pictures
  /// that have nothing to do with it.
  Future<List<TransferredPhoto>> listTransferred() async {
    final dir = await destinationDirectory();
    if (!await dir.exists()) return const [];

    final photos = <TransferredPhoto>[];
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      if (p.extension(entry.path).toLowerCase() == '.part') continue;
      photos.add(
        TransferredPhoto(
          file: entry,
          takenAt: await entry.lastModified(),
        ),
      );
    }
    photos.sort((a, b) => b.takenAt.compareTo(a.takenAt));
    return photos;
  }

  /// Removes shots from the local download cache — the album's backing
  /// store. Copies already made into the Photos album or a chosen
  /// destination folder are untouched; this only makes the album forget
  /// them. A deleted shot will also be transferable again, since the
  /// skip-existing check looks at this same folder.
  Future<void> deleteTransferred(Iterable<TransferredPhoto> photos) async {
    for (final photo in photos) {
      if (await photo.file.exists()) await photo.file.delete();
    }
  }

  /// Transfers [items] one download at a time, reporting each result as it
  /// lands.
  ///
  /// Filing a finished shot into the gallery is disk I/O, not network I/O, so
  /// it runs while the *next* shot downloads instead of serializing the two.
  /// On phones with slower storage than the network link, that copy can cost
  /// as much wall-clock time as the download itself; overlapping it is what
  /// keeps the network saturated instead of idling between shots.
  ///
  /// [onProgress] reports the shot currently in flight, throttled to
  /// [_progressInterval] so the UI cannot starve the download.
  Stream<TransferResult> transferAll(
    List<CameraItem> items, {
    void Function(TransferProgress progress)? onProgress,
  }) {
    final controller = StreamController<TransferResult>();
    unawaited(_runTransfer(items, onProgress, controller));
    return controller.stream;
  }

  Future<void> _runTransfer(
    List<CameraItem> items,
    void Function(TransferProgress progress)? onProgress,
    StreamController<TransferResult> controller,
  ) async {
    // Keeps results in the same order as [items] while letting each shot's
    // gallery copy run in the background: the future itself starts the
    // moment a download finishes, but this chain only controls *when its
    // result is emitted* — so a quick gallery copy is reported to the caller
    // as soon as it is actually done, rather than sitting unreported until
    // however long the next shot's download happens to take (which used to
    // leave the "done" counter looking stuck, then jumping).
    var emitted = Future<void>.value();
    void enqueue(Future<TransferResult> result) {
      emitted = emitted.then((_) async => controller.add(await result));
    }

    try {
      final dir = await destinationDirectory();
      _sessionBytes = 0;
      _lastEmitMs = 0;
      _clock
        ..reset()
        ..start();

      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final position = i + 1;
        if (_cancelled) break;

        if (item.isRawOnly) {
          enqueue(
            Future.value(
              TransferResult(
                item,
                TransferOutcome.skippedRaw,
                detail: 'raw only — camera serves no full-size JPEG',
              ),
            ),
          );
          continue;
        }

        final resource = item.original!;
        final file = File(p.join(dir.path, item.fileName));

        if (await file.exists() &&
            resource.byteSize != null &&
            await file.length() == resource.byteSize) {
          enqueue(
            Future.value(TransferResult(item, TransferOutcome.skippedExisting)),
          );
          continue;
        }

        try {
          await _download(item, position, resource, file, onProgress);
        } catch (e) {
          if (await file.exists()) await file.delete();
          enqueue(
            Future.value(
              TransferResult(item, TransferOutcome.failed, detail: '$e'),
            ),
          );
          continue;
        }

        // The bytes are down; hand the copy into the gallery to the
        // background so it overlaps with the next download.
        enqueue(_insertIntoGallery(item, file));
      }
    } finally {
      await emitted;
      await controller.close();
    }
  }

  Future<TransferResult> _insertIntoGallery(CameraItem item, File file) async {
    try {
      await _addToGallery(file);
      return TransferResult(item, TransferOutcome.saved);
    } catch (e) {
      if (await file.exists()) await file.delete();
      return TransferResult(item, TransferOutcome.failed, detail: '$e');
    }
  }

  void _emitProgress(
    CameraItem item,
    int position,
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
        position: position,
        received: received,
        total: total,
        bytesPerSecond: averageBytesPerSecond,
      ),
    );
  }

  Future<void> _download(
    CameraItem item,
    int position,
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
    _emitProgress(item, position, 0, total, onProgress, force: true);

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
        _emitProgress(item, position, received, total, onProgress);
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

    // Stamp the file with the camera's capture time, so the shot date
    // survives without a separate database — the local album groups its
    // timeline by this. Shots the camera reported no date for keep the
    // download time, the closest thing available.
    final captured = item.captured;
    if (captured != null) await file.setLastModified(captured);
  }

  Future<void> _addToGallery(File file) async {
    final custom = _saveToGallery;
    if (custom != null) return custom(file);

    final folderName = await DestinationFolder.currentName();
    if (folderName != null) {
      final saved = await DestinationFolder.save(
        sourcePath: file.path,
        fileName: p.basename(file.path),
      );
      if (saved.ok) return;
      // Do not fall back to the Photos album when the user explicitly chose
      // a folder — that is exactly how shots used to "disappear" into
      // SonyTransfer while the UI still claimed they were going elsewhere.
      throw Exception(
        'Could not save to $folderName'
        '${saved.reason == null ? '' : ' (${saved.reason})'}. '
        'Pick the folder again, or Reset to use the Photos album.',
      );
    }

    if (!await Gal.hasAccess()) {
      await Gal.requestAccess();
    }
    await Gal.putImage(file.path, album: albumName);
  }
}
