import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sony_transfer/models/camera_item.dart';
import 'package:sony_transfer/services/transfer_service.dart';

const int _chunkSize = 1024;

CameraItem _jpeg({required int byteSize, String title = 'DSC00001.JPG'}) =>
    CameraItem(
      id: title,
      title: title,
      folder: '100MSDCF',
      resources: [
        CameraResource(
          url: 'http://192.168.122.1:60152/orig.jpg',
          byteSize: byteSize,
          resolution: '7952x5304',
          protocolInfo: 'http-get:*:image/jpeg:*',
        ),
      ],
    );

CameraItem get _raw => CameraItem(
      id: '0002',
      title: 'DSC00002.ARW',
      folder: '100MSDCF',
      resources: const [
        CameraResource(
          url: 'http://192.168.122.1:60152/raw_lrg.jpg',
          protocolInfo: 'http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG',
        ),
      ],
    );

/// Serves [chunks] separate chunks, the way a real streamed download arrives.
http.Client _streamingClient(int chunks, {Duration delay = Duration.zero}) =>
    MockClient.streaming(
      (request, bodyStream) async {
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        return http.StreamedResponse(
          Stream.fromIterable(
            List.generate(chunks, (_) => Uint8List(_chunkSize)),
          ),
          200,
          contentLength: chunks * _chunkSize,
        );
      },
    );

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sony_transfer_test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  TransferService serviceWith(http.Client client) => TransferService(
        client: client,
        destination: temp,
        saveToGallery: (_) async {},
      );

  test('throttles progress instead of reporting every chunk', () async {
    const chunks = 500;
    final service = serviceWith(_streamingClient(chunks));
    final updates = <TransferProgress>[];

    final results = await service
        .transferAll([_jpeg(byteSize: chunks * _chunkSize)],
            onProgress: updates.add)
        .toList();

    expect(results.single.outcome, TransferOutcome.saved);

    // The point of the throttle: a chunk-per-callback would repaint the UI 500
    // times and starve the download on the single Dart isolate.
    expect(updates.length, lessThan(chunks ~/ 10));
    expect(updates.last.received, chunks * _chunkSize);
  });

  test('always reports the final byte count', () async {
    const chunks = 8;
    final service = serviceWith(_streamingClient(chunks));
    final updates = <TransferProgress>[];

    await service
        .transferAll([_jpeg(byteSize: chunks * _chunkSize)],
            onProgress: updates.add)
        .toList();

    expect(updates, isNotEmpty);
    expect(updates.last.received, updates.last.total);
  });

  test('opens each shot at zero bytes so a per-shot bar resets', () async {
    const chunks = 4;
    const size = chunks * _chunkSize;
    final service = serviceWith(_streamingClient(chunks));
    final updates = <TransferProgress>[];

    await service.transferAll(
      [
        _jpeg(byteSize: size, title: 'A.JPG'),
        _jpeg(byteSize: size, title: 'B.JPG'),
      ],
      onProgress: updates.add,
    ).toList();

    for (final title in ['A.JPG', 'B.JPG']) {
      final forShot = updates.where((u) => u.item.title == title).toList();
      // Without an opening report the bar would hold the previous shot's 100%
      // until the first chunk of this one arrived.
      expect(forShot.first.received, 0, reason: title);
      expect(forShot.last.received, size, reason: title);
      // Sized per shot, not per batch, which is what the bar divides by.
      expect(forShot.first.total, size, reason: title);
    }
  });

  test('writes the file and measures throughput', () async {
    const chunks = 64;
    final service = serviceWith(_streamingClient(chunks));

    await service.transferAll([_jpeg(byteSize: chunks * _chunkSize)]).toList();

    final written = File(p.join(temp.path, 'DSC00001.JPG'));
    expect(written.existsSync(), isTrue);
    expect(written.lengthSync(), chunks * _chunkSize);
    expect(service.averageBytesPerSecond, greaterThan(0));
  });

  test('leaves no .part file behind on success', () async {
    const chunks = 4;
    final service = serviceWith(_streamingClient(chunks));

    await service.transferAll([_jpeg(byteSize: chunks * _chunkSize)]).toList();

    expect(File(p.join(temp.path, 'DSC00001.JPG.part')).existsSync(), isFalse);
  });

  test('skips raw-only shots without touching the network', () async {
    var requests = 0;
    final service = serviceWith(
      MockClient((request) async {
        requests++;
        return http.Response('should not be fetched', 200);
      }),
    );

    final results = await service.transferAll([_raw]).toList();

    expect(results.single.outcome, TransferOutcome.skippedRaw);
    expect(requests, 0);
  });

  test('overlaps the gallery copy with the next download', () async {
    const chunks = 4;
    const size = chunks * _chunkSize;
    const step = Duration(milliseconds: 40);
    final galleryCalls = <String>[];
    final service = TransferService(
      client: _streamingClient(chunks, delay: step),
      destination: temp,
      saveToGallery: (file) async {
        galleryCalls.add(p.basename(file.path));
        await Future<void>.delayed(step);
      },
    );

    final stopwatch = Stopwatch()..start();
    final results = await service.transferAll([
      _jpeg(byteSize: size, title: 'A.JPG'),
      _jpeg(byteSize: size, title: 'B.JPG'),
      _jpeg(byteSize: size, title: 'C.JPG'),
    ]).toList();
    stopwatch.stop();

    expect(results.map((r) => r.item.title).toList(), ['A.JPG', 'B.JPG', 'C.JPG']);
    expect(results.every((r) => r.outcome == TransferOutcome.saved), isTrue);
    expect(galleryCalls, ['A.JPG', 'B.JPG', 'C.JPG']);
    // Fully serialized (3 downloads + 3 gallery copies, each one `step`)
    // would take ~6 steps. Overlapped, a gallery copy hides behind the next
    // download and the batch should finish in roughly 4 steps instead.
    expect(stopwatch.elapsed, lessThan(step * 5));
  });

  test(
    'reports a shot as done once its gallery copy finishes, not once the '
    'next shot finishes downloading',
    () async {
      const chunks = 4;
      const size = chunks * _chunkSize;
      // The next download takes far longer than the gallery copy — the
      // realistic case, since filing a shot into the gallery is a local
      // disk copy while the download crosses a slow camera Wi-Fi link.
      const downloadDelay = Duration(milliseconds: 200);
      final galleryFinishedAt = <String, int>{};
      final resultReceivedAt = <String, int>{};
      final stopwatch = Stopwatch()..start();

      final service = TransferService(
        client: _streamingClient(chunks, delay: downloadDelay),
        destination: temp,
        saveToGallery: (file) async {
          galleryFinishedAt[p.basename(file.path)] = stopwatch.elapsedMilliseconds;
        },
      );

      await for (final result in service.transferAll([
        _jpeg(byteSize: size, title: 'A.JPG'),
        _jpeg(byteSize: size, title: 'B.JPG'),
      ])) {
        resultReceivedAt[result.item.title] = stopwatch.elapsedMilliseconds;
      }

      // A's gallery copy is essentially instantaneous, so its result should
      // reach the caller shortly after — not get held back until B's
      // download (a further 200ms away) also finishes.
      final lag = resultReceivedAt['A.JPG']! - galleryFinishedAt['A.JPG']!;
      expect(lag, lessThan(downloadDelay.inMilliseconds ~/ 2));
    },
  );

  test('skips a file already on disk at the advertised size', () async {
    const chunks = 4;
    const size = chunks * _chunkSize;
    File(p.join(temp.path, 'DSC00001.JPG')).writeAsBytesSync(Uint8List(size));

    var requests = 0;
    final service = serviceWith(
      MockClient((request) async {
        requests++;
        return http.Response('', 200);
      }),
    );

    final results =
        await service.transferAll([_jpeg(byteSize: size)]).toList();

    expect(results.single.outcome, TransferOutcome.skippedExisting);
    expect(requests, 0);
  });
}
