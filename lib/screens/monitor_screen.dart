import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/camera_ssid.dart';
import '../services/monitor_session.dart';
import '../services/network_binding.dart';
import '../services/saved_wifi_credentials.dart';
import '../services/scalar_camera.dart';
import '../services/shot_ingest.dart';
import '../services/transfer_service.dart';

enum _Stage { setup, connecting, live }

/// Live view from the A7R III, plus a copy of each new JPEG that does not
/// take the camera out of shooting.
///
/// Ctrl w/ Smartphone is the mode that can do both at once. Send to
/// Smartphone cannot: it replaces the shooting screen until the send ends.
class MonitorScreen extends StatefulWidget {
  const MonitorScreen({
    super.key,
    required this.onBack,
    this.onPhotoSaved,
    this.active = true,
    this.transferService,
  });

  final VoidCallback onBack;

  /// Fired after a JPEG lands in the album cache, so the album underneath
  /// can pick it up without waiting for the next manual refresh.
  final VoidCallback? onPhotoSaved;

  /// False while another pane is covering this one. The session keeps
  /// running; only the "keep the screen awake" flag follows visibility.
  final bool active;

  final TransferService? transferService;

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  final TextEditingController _ssid = TextEditingController();
  final TextEditingController _password = TextEditingController();

  late final TransferService _transfer;

  _Stage _stage = _Stage.setup;
  String? _error;
  String _status = '';
  String? _cameraName;
  String? _lastSaved;
  Uint8List? _frame;
  Uint8List? _pendingFrame;
  bool _frameScheduled = false;
  DateTime? _lastPaint;
  DateTime? _fpsWindow;
  int _fpsFrames = 0;
  double _fps = 0;
  int _saving = 0;
  bool _autoTransfer = true;
  bool _canShutter = false;
  bool _shutterBusy = false;
  bool _scanning = false;
  bool _weJoined = false;
  bool _bound = false;
  List<String> _networks = const [];
  Map<String, String> _bssids = const {};
  WifiScanProblem? _scanProblem;

  MonitorSession? _session;

  @override
  void initState() {
    super.initState();
    _createdTransfer = widget.transferService == null;
    _transfer = widget.transferService ?? TransferService();
    _restore();
  }

  bool _createdTransfer = false;

  @override
  void didUpdateWidget(covariant MonitorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      unawaited(_applyScreen());
    }
  }

  @override
  void dispose() {
    _ssid.dispose();
    _password.dispose();
    final session = _session;
    _session = null;
    unawaited(session?.stop());
    unawaited(NetworkBinding.setKeepScreenOn(false));
    unawaited(NetworkBinding.setMonitorSession(active: false));
    if (_weJoined) {
      unawaited(NetworkBinding.disconnectWifi());
    } else if (_bound) {
      unawaited(NetworkBinding.releaseBind());
    }
    if (_createdTransfer) _transfer.close();
    super.dispose();
  }

  Future<void> _restore() async {
    final saved = await SavedWifiCredentials.load();
    if (!mounted) return;
    setState(() {
      if (saved.ssid != null && saved.ssid!.isNotEmpty) {
        _ssid.text = saved.ssid!;
      }
      if (saved.password != null) _password.text = saved.password!;
    });
    await _scan(autoStart: true);
  }

  Future<void> _scan({bool autoStart = false}) async {
    if (_scanning || _stage != _Stage.setup) return;
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final scan = await NetworkBinding.scanCameraWifi();
      if (!mounted || _stage != _Stage.setup) return;
      setState(() {
        _networks = scan.cameras;
        _bssids = scan.bssids;
        _scanProblem = scan.problem;
        _scanning = false;
        if (_ssid.text.trim().isEmpty && scan.cameras.length == 1) {
          _ssid.text = scan.cameras.single;
        }
      });
      final ssid = _ssid.text.trim();
      final remembered = scan.cameras.contains(ssid) ||
          (ssid.isEmpty && scan.cameras.length == 1);
      if (autoStart &&
          remembered &&
          _password.text.isNotEmpty &&
          _stage == _Stage.setup) {
        if (ssid.isEmpty) _ssid.text = scan.cameras.single;
        unawaited(_start());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = '$e';
      });
    }
  }

  Future<void> _start({bool alreadyOnWifi = false}) async {
    if (_stage == _Stage.connecting) return;
    setState(() {
      _stage = _Stage.connecting;
      _error = null;
      _status = alreadyOnWifi
          ? 'Using the Wi-Fi you joined…'
          : 'Joining the camera Wi-Fi…';
    });

    final ssid = _ssid.text.trim();
    final password = _password.text;
    final current = await NetworkBinding.currentWifiSsid();
    final already = alreadyOnWifi ||
        (current != null && looksLikeCameraSsid(current));

    if (password.isNotEmpty && !already) {
      final joined = await NetworkBinding.joinCameraWifi(
        ssid: ssid,
        password: password,
        bssid: _bssids[ssid],
      );
      if (!mounted) return;
      if (!joined.ok) {
        setState(() {
          _stage = _Stage.setup;
          _status = '';
          _error = _joinFailed(joined, ssid);
        });
        return;
      }
      _weJoined = true;
      if (ssid.isNotEmpty) {
        await SavedWifiCredentials.save(ssid: ssid, password: password);
      }
    } else {
      _bound = await NetworkBinding.bindToWifi();
      if (password.isNotEmpty && ssid.isNotEmpty) {
        await SavedWifiCredentials.save(ssid: ssid, password: password);
      }
    }
    if (!mounted) return;

    setState(() => _status = 'Looking for the remote-shooting service…');
    await NetworkBinding.setMulticastLock(true);
    final DiscoveredCamera found;
    try {
      final gateway = await NetworkBinding.wifiGateway();
      found = await discoverScalarCamera(
        hosts: [
          if (gateway != null && gateway.isNotEmpty) gateway,
          '192.168.122.1',
        ],
      );
    } on ScalarException catch (e) {
      await _failStart(e.message);
      return;
    } catch (e) {
      await _failStart('$e');
      return;
    } finally {
      await NetworkBinding.setMulticastLock(false);
    }
    if (!mounted) return;

    final session = MonitorSession(
      camera: ScalarCamera(endpoint: found.endpoint),
      ingest: ShotIngest(_transfer),
      apis: found.apis,
      onFrame: _onFrame,
      onMessage: (message) {
        if (!mounted) return;
        setState(() => _status = message);
      },
      onSaving: (name) {
        if (!mounted) return;
        setState(() {
          _saving += 1;
          _status = 'Copying $name — keep shooting';
        });
        unawaited(
          NetworkBinding.setMonitorSession(
            active: true,
            text: 'Copying $name',
          ),
        );
      },
      onSaved: (name) {
        if (!mounted) return;
        setState(() {
          _saving = (_saving - 1).clamp(0, 99);
          _lastSaved = name;
        });
        widget.onPhotoSaved?.call();
        unawaited(
          NetworkBinding.setMonitorSession(
            active: true,
            text: 'Saved $name',
          ),
        );
      },
      onSaveFailed: (message) {
        if (!mounted) return;
        setState(() {
          _saving = (_saving - 1).clamp(0, 99);
          _error = message;
        });
      },
      onSessionError: (message) {
        if (!mounted) return;
        setState(() => _error = message);
      },
    );
    _session = session;
    session.autoTransfer = _autoTransfer;
    // Live before start() so the first frames are not dropped while the
    // open call is still returning.
    setState(() {
      _stage = _Stage.live;
      _cameraName = found.name ?? 'A7R III';
      _canShutter = session.canReleaseShutter;
      _status = 'Starting live view…';
      _error = null;
    });
    try {
      await session.start();
    } catch (e) {
      await session.stop();
      if (identical(_session, session)) _session = null;
      await _failStart(e is ScalarException ? e.message : '$e');
      return;
    }
    if (!mounted) return;
    setState(() => _status = session.statusLine);
    await NetworkBinding.setMonitorSession(
      active: true,
      text: 'Live view on. New photos copy in the background.',
    );
    await _applyScreen();
  }

  String _joinFailed(WifiJoinResult joined, String ssid) {
    final name = ssid.isEmpty ? 'the DIRECT- network' : ssid;
    final lead = joined.message ?? 'Could not establish a connection to $name.';
    if (joined.code != 'unavailable' && joined.code != 'opened_settings') {
      return lead;
    }
    return '$lead\n\n'
        'Leave the camera on Connection, with the password still on screen. '
        'Join $name in the phone\'s Wi-Fi settings, then tap Use this Wi-Fi.';
  }

  Future<void> _failStart(String message) async {
    await NetworkBinding.setMulticastLock(false);
    if (_weJoined) {
      await NetworkBinding.disconnectWifi();
      _weJoined = false;
    } else if (_bound) {
      await NetworkBinding.releaseBind();
      _bound = false;
    }
    if (!mounted) return;
    setState(() {
      _stage = _Stage.setup;
      _frame = null;
      _pendingFrame = null;
      _status = '';
      _error = message;
    });
  }

  Future<void> _disconnect() async {
    final session = _session;
    _session = null;
    setState(() {
      _stage = _Stage.setup;
      _frame = null;
      _pendingFrame = null;
      _status = 'Disconnecting…';
      _fps = 0;
    });
    await session?.stop();
    await NetworkBinding.setKeepScreenOn(false);
    await NetworkBinding.setMonitorSession(active: false);
    if (_weJoined) {
      await NetworkBinding.disconnectWifi();
    } else if (_bound) {
      await NetworkBinding.releaseBind();
    }
    _weJoined = false;
    _bound = false;
    if (!mounted) return;
    setState(() => _status = '');
  }

  Future<void> _applyScreen() async {
    await NetworkBinding.setKeepScreenOn(
      widget.active && _stage == _Stage.live,
    );
  }

  void _onFrame(Uint8List jpeg) {
    if (!mounted || _stage != _Stage.live) return;
    _pendingFrame = jpeg;
    _fpsFrames++;
    final now = DateTime.now();
    final window = _fpsWindow;
    if (window == null || now.difference(window) >= const Duration(seconds: 1)) {
      final seconds = window == null
          ? 1.0
          : now.difference(window).inMilliseconds / 1000;
      _fps = _fpsFrames / (seconds == 0 ? 1 : seconds);
      _fpsFrames = 0;
      _fpsWindow = now;
    }
    if (_frameScheduled) return;
    _frameScheduled = true;
    final elapsed =
        _lastPaint == null ? const Duration(milliseconds: 66) : now.difference(_lastPaint!);
    final wait = elapsed >= const Duration(milliseconds: 66)
        ? Duration.zero
        : const Duration(milliseconds: 66) - elapsed;
    Future<void>.delayed(wait, () {
      _frameScheduled = false;
      if (!mounted || _pendingFrame == null) return;
      _lastPaint = DateTime.now();
      setState(() => _frame = _pendingFrame);
    });
  }

  Future<void> _shutter() async {
    final session = _session;
    if (session == null || _shutterBusy) return;
    setState(() => _shutterBusy = true);
    try {
      await session.releaseShutter();
    } finally {
      if (mounted) setState(() => _shutterBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_stage == _Stage.live) return _live(context);
    return _setup(context);
  }

  Widget _setup(BuildContext context) {
    final busy = _stage == _Stage.connecting;
    final hint = _scanHint(_scanProblem);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: widget.onBack),
        title: const Text('Live monitor'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Shoot on the camera. This screen shows the live view and copies '
            'each new JPEG without leaving shooting mode.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          Text(
            'On the A7R III',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            '1. MENU → Network → Ctrl w/ Smartphone → On.\n'
            '2. Open Connection and leave that screen up. It shows the '
            'DIRECT- network name and password.\n'
            '3. Join that network below, then shoot normally on the body. '
            'The shutter stays on the camera while a photo is copying.\n'
            '4. If the phone says it could not establish a connection, join '
            'the same DIRECT- network in system Wi-Fi settings and tap '
            'Use this Wi-Fi. Keep the camera Connection screen up the whole time.',
          ),
          const SizedBox(height: 8),
          Text(
            'Send to Smartphone is a different mode. It cannot show a live '
            'view, and the camera waits on that screen until the send ends.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Text('Camera Wi-Fi', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                onPressed: busy || _scanning ? null : () => _scan(),
                icon: _scanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_find),
                label: const Text('Scan'),
              ),
            ],
          ),
          if (_networks.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [
                for (final ssid in _networks)
                  ChoiceChip(
                    label: Text(ssid),
                    selected: _ssid.text.trim() == ssid,
                    onSelected: busy
                        ? null
                        : (_) => setState(() => _ssid.text = ssid),
                  ),
              ],
            ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              hint,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            if (_scanProblem == WifiScanProblem.locationOff)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: NetworkBinding.openLocationSettings,
                  child: const Text('Open Location settings'),
                ),
              ),
            if (_scanProblem == WifiScanProblem.permissionDenied)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: NetworkBinding.openAppSettings,
                  child: const Text('Open app settings'),
                ),
              ),
            if (_scanProblem == WifiScanProblem.wifiOff)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: NetworkBinding.openWifiSettings,
                  child: const Text('Open Wi-Fi settings'),
                ),
              ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _ssid,
            enabled: !busy,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Network name',
              hintText: 'DIRECT-…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            enabled: !busy,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
            onSubmitted: busy ? null : (_) => _start(),
          ),
          const SizedBox(height: 16),
          if (_status.isNotEmpty) ...[
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(_status)),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (_error != null) ...[
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: busy ? null : () => _start(),
            icon: const Icon(Icons.live_tv),
            label: Text(busy ? 'Connecting…' : 'Start monitor'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy ? null : NetworkBinding.openWifiSettings,
              icon: const Icon(Icons.wifi),
              label: const Text('Open Wi-Fi settings'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: busy ? null : () => _start(alreadyOnWifi: true),
              icon: const Icon(Icons.link),
              label: const Text('Use this Wi-Fi'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _live(BuildContext context) {
    final frame = _frame;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (frame == null)
            const Center(child: CircularProgressIndicator())
          else
            Image.memory(
              frame,
              gaplessPlayback: true,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox.shrink(),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _scrim(
              top: true,
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back to album',
                      onPressed: widget.onBack,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _cameraName ?? 'Live monitor',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            _fps > 0 ? '${_fps.toStringAsFixed(0)} fps' : 'Live view',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _disconnect,
                      child: const Text('Disconnect'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _scrim(
              top: false,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(_status),
                      if (_saving > 0)
                        Text(
                          _saving == 1
                              ? '1 photo copying'
                              : '$_saving photos copying',
                        ),
                      if (_lastSaved != null)
                        Text(
                          'Last copy: $_lastSaved',
                          style: const TextStyle(fontSize: 12),
                        ),
                      if (_error != null)
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Copy each new photo'),
                        value: _autoTransfer,
                        onChanged: (value) {
                          setState(() => _autoTransfer = value);
                          _session?.autoTransfer = value;
                        },
                      ),
                      if (_canShutter)
                        Center(
                          child: IconButton.filled(
                            tooltip: 'Shutter',
                            iconSize: 36,
                            onPressed: _shutterBusy ? null : _shutter,
                            icon: const Icon(Icons.camera),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scrim({required Widget child, required bool top}) {
    if (!top) {
      return ColoredBox(
        color: const Color(0xF2000000),
        child: child,
      );
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xE6000000), Color(0x00000000)],
        ),
      ),
      child: child,
    );
  }
}

String? _scanHint(WifiScanProblem? problem) => switch (problem) {
      WifiScanProblem.wifiOff => 'Wi-Fi is off.',
      WifiScanProblem.permissionDenied =>
        'Allow location or nearby Wi-Fi so the camera network can be found.',
      WifiScanProblem.locationOff =>
        'Turn location on. Android hides Wi-Fi names without it.',
      WifiScanProblem.throttled =>
        'Android is limiting scans. Type the DIRECT- name from the camera.',
      WifiScanProblem.noneFound =>
        'No DIRECT- network in range. Open Ctrl w/ Smartphone → Connection.',
      WifiScanProblem.unsupported => 'Wi-Fi scan is only available on Android.',
      null => null,
    };
