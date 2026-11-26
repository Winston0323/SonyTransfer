import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'live_view_parser.dart';
import 'scalar_camera.dart';
import 'shot_ingest.dart';

/// Live view plus a shutter watcher.
///
/// The two run on separate HTTP connections. Copying a JPEG never sends a
/// command that leaves shooting mode, and the next shutter wait is armed
/// again as soon as the camera hands back a URL — the download itself does
/// not have to finish first.
class MonitorSession {
  MonitorSession({
    required ScalarCamera camera,
    required ShotIngest ingest,
    required this.apis,
    required this.onFrame,
    this.onMessage,
    this.onSaving,
    this.onSaved,
    this.onSaveFailed,
    this.onSessionError,
  })  : _camera = camera,
        _ingest = ingest;

  final ScalarCamera _camera;
  final ShotIngest _ingest;
  final List<String> apis;
  final void Function(Uint8List jpeg) onFrame;
  final void Function(String message)? onMessage;
  final void Function(String name)? onSaving;
  final void Function(String name)? onSaved;
  final void Function(String message)? onSaveFailed;
  final void Function(String message)? onSessionError;

  bool autoTransfer = true;
  String? postviewSize;
  bool _stopped = false;
  bool _shutterBusy = false;
  String? _liveUrl;
  String? _lastEventUrl;
  HttpClient? _liveClient;
  Future<void>? _liveTask;
  Future<void>? _watchTask;
  Future<void>? _stopOnce;

  /// Serializes command calls. The camera serves one JSON-RPC at a time;
  /// the live-view stream and the JPEG download stay off this queue so a
  /// copy does not sit in front of the next shutter wait.
  Future<void> _chain = Future<void>.value();

  bool get canReleaseShutter => apis.contains('actTakePicture');

  bool get watchesBodyShutter =>
      apis.contains('awaitTakePicture') || apis.contains('getEvent');

  Future<void> start() async {
    postviewSize = await _camera.preparePostview(apis);
    _liveUrl = await _camera.openLiveView(apis);
    onMessage?.call(statusLine);
    _liveTask = _liveLoop();
    _watchTask = _watchLoop();
  }

  String get statusLine {
    final size = switch (postviewSize) {
      'Original' => 'Copies the original JPEG.',
      '2M' => 'Copies a 2M JPEG. The full file and any RAW stay on the card.',
      'VGA' => 'Copies a small JPEG. The full file and any RAW stay on the card.',
      _ => 'Copies each new JPEG. RAW stays on the card.',
    };
    if (apis.contains('awaitTakePicture')) {
      return 'Shoot on the camera. $size '
          'A copy in progress does not lock the shutter.';
    }
    if (apis.contains('getEvent')) {
      return 'Shoot on the camera. $size';
    }
    if (canReleaseShutter) {
      return 'Use the shutter button on this screen. $size';
    }
    return size;
  }

  /// Phone shutter. Aborts the body-shutter wait so this call can use the
  /// camera's one command connection, then the wait is armed again.
  Future<void> releaseShutter() async {
    if (!canReleaseShutter || _stopped || _shutterBusy) return;
    _shutterBusy = true;
    _camera.abortInFlight();
    try {
      final url = await _exclusive(() async {
        if (_stopped) return null;
        return pickShotUrl(await _camera.takePicture());
      });
      if (url != null && !_stopped) await _save(Uri.parse(url));
    } on ScalarException catch (e) {
      onSaveFailed?.call(e.message);
    } finally {
      _shutterBusy = false;
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final run = _chain.then((_) => action());
    _chain = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> stop() {
    if (_stopOnce != null) return _stopOnce!;
    _stopped = true;
    _liveClient?.close(force: true);
    _camera.abortInFlight();
    _stopOnce = _finishStop();
    return _stopOnce!;
  }

  Future<void> _finishStop() async {
    try {
      await _liveTask;
    } catch (_) {}
    try {
      await _watchTask;
    } catch (_) {}
    try {
      await _camera.stopLiveView(apis);
    } catch (_) {}
    _camera.close();
    _ingest.close();
  }

  Future<void> _liveLoop() async {
    var failures = 0;
    while (!_stopped) {
      final url = _liveUrl;
      if (url == null) return;
      try {
        await _readStream(Uri.parse(url));
        failures = 0;
      } catch (e) {
        if (_stopped) return;
        failures++;
        if (failures > 6) {
          onSessionError?.call('Live view stopped ($e).');
          return;
        }
      }
      if (_stopped) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (_stopped) return;
      try {
        _liveUrl = await _camera.openLiveView(apis);
      } on ScalarException catch (e) {
        if (_stopped) return;
        failures++;
        if (failures > 6) {
          onSessionError?.call(e.message);
          return;
        }
      }
    }
  }

  Future<void> _readStream(Uri url) async {
    final client = HttpClient()..idleTimeout = const Duration(minutes: 10);
    _liveClient = client;
    try {
      final request = await client.getUrl(url);
      final response =
          await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw ScalarException('Live view returned HTTP ${response.statusCode}.');
      }
      final parser = LiveViewParser();
      await for (final chunk in response) {
        if (_stopped) return;
        final frames = parser.add(chunk);
        if (frames.isNotEmpty) onFrame(frames.last);
      }
    } finally {
      client.close(force: true);
      if (identical(_liveClient, client)) _liveClient = null;
    }
  }

  Future<void> _watchLoop() async {
    while (!_stopped) {
      if (!autoTransfer || _shutterBusy || !watchesBodyShutter) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        continue;
      }
      String? url;
      try {
        url = await _exclusive(() async {
          if (_stopped || !autoTransfer || _shutterBusy) return null;
          final urls = apis.contains('awaitTakePicture')
              ? await _camera.awaitNextPicture()
              : _newEventUrls(await _camera.pollPictureEvents());
          return pickShotUrl(urls);
        });
      } on ScalarException catch (e) {
        if (_stopped || _shutterBusy) continue;
        if (e.retryable) continue;
        onSaveFailed?.call(e.message);
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      } catch (e) {
        if (_stopped || _shutterBusy) continue;
        onSaveFailed?.call('$e');
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      if (_stopped) return;
      if (url == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }
      unawaited(_save(Uri.parse(url)));
    }
  }

  List<String> _newEventUrls(List<String> urls) {
    final url = pickShotUrl(urls);
    if (url == null || url == _lastEventUrl) return const [];
    _lastEventUrl = url;
    return [url];
  }

  Future<void> _save(Uri url) async {
    final name = fileNameFromCameraUrl(url);
    onSaving?.call(name);
    onMessage?.call('Copying $name — keep shooting');
    try {
      final saved = await _ingest.save(url);
      onSaved?.call(saved);
      onMessage?.call('Saved $saved. $statusLine');
    } on Object catch (e) {
      onSaveFailed?.call(
        'Could not copy $name ($e). The photo is still on the card.',
      );
    }
  }
}
