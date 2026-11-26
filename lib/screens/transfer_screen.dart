import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/camera_item.dart';
import '../models/timeline.dart';
import '../services/destination_folder.dart';
import '../services/network_binding.dart';
import '../services/saved_wifi_credentials.dart';
import '../services/sony_camera_client.dart';
import '../services/transfer_service.dart';
import '../widgets/timeline_view.dart';
import '../widgets/transfer_bottom_bar.dart';

enum _Stage { idle, connecting, connected, transferring, finished }

/// Shrinks a [TextButton] to its text size. The default Material tap target
/// is generous enough that a row of these next to a status line is what tips
/// the setup panel into overflowing on shorter screens.
final ButtonStyle _compactButtonStyle = TextButton.styleFrom(
  minimumSize: Size.zero,
  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
);

/// The camera connect + browse + transfer flow. [HomeShell] keeps it alive
/// beside the album rather than pushing it as a route: popping a route would
/// dispose this state, whose teardown drops the camera's Wi-Fi — so "back"
/// merely hides the screen and the connection survives.
class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key, this.onBack});

  /// Returns to the album. Shown as the app-bar back button — there is no
  /// route to pop, since leaving must not dispose this screen.
  final VoidCallback? onBack;

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  final TextEditingController _hostController =
      TextEditingController(text: SonyCameraClient.defaultHost);
  final TextEditingController _ssidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final TransferService _transfer = TransferService();

  SonyCameraClient? _client;
  StreamSubscription<List<CameraItem>>? _listing;
  _Stage _stage = _Stage.idle;
  bool _autoDetect = true;

  /// Whether shots are still arriving from the camera.
  bool _loading = false;

  List<String> _cameraNetworks = const [];
  List<String> _allNetworks = const [];
  WifiScanProblem? _scanProblem;
  bool _showAllNetworks = false;
  String? _selectedSsid;
  bool _scanning = false;
  String? _rememberedSsid;

  /// Whether a sighting of the remembered camera network should join
  /// automatically rather than waiting for a tap on Connect.
  bool _autoConnect = true;

  /// The SSID auto-connect last tried, so a failed attempt (e.g. a stale
  /// password) does not retry every scan while the network stays in range.
  /// Cleared once that network drops out of range, so the next sighting —
  /// after a password fix, or just the camera being turned back on — tries
  /// again.
  String? _autoConnectedSsid;

  /// Rescans periodically while idle, which is what makes "auto-connect"
  /// mean turning the camera on rather than having to reopen the app.
  Timer? _autoScanTimer;

  /// Polls whether the camera's Wi-Fi is still associated while connected, so
  /// switching the camera off sends the app back to the setup screen instead
  /// of sitting on a now-stale shot list.
  Timer? _connectionWatchdog;
  int _wifiMissCount = 0;

  /// Bumped by [_reset] so a transfer loop or connect attempt already in
  /// flight can tell it has been superseded and should stop touching state.
  int _sessionId = 0;

  List<CameraItem> _items = const [];
  List<TimelineSection> _sections = const [];
  final Set<String> _selected = {};
  final Map<String, TransferOutcome> _outcomes = {};

  String? _cameraName;
  String? _error;
  String _status = '';

  /// Wi-Fi radio characteristics, when Android will report them. A phone stuck
  /// at a fraction of a tablet's speed on the same camera almost always shows
  /// up here first — a radio/antenna gap or a weak signal, not something the
  /// download code controls.
  WifiLinkInfo _linkInfo = const WifiLinkInfo();

  /// Kept out of [setState] so a progress tick repaints only the bottom bar
  /// rather than the whole screen, including the shot list.
  final ValueNotifier<TransferProgress?> _progress = ValueNotifier(null);

  int _done = 0;
  int _queueLength = 0;

  /// Folder the user redirected saves to via [DestinationFolder.pick], or
  /// null when saving to the default Photos album.
  String? _destinationFolderName;

  @override
  void initState() {
    super.initState();
    _restoreCredentials();
    _loadDestinationFolder();
    _autoScanTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_stage == _Stage.idle && !_scanning) _scanNetworks();
    });
    _connectionWatchdog = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkCameraStillReachable(),
    );
  }

  /// Detects the camera switching its Wi-Fi off (or the phone drifting onto
  /// another network) and, once confirmed, sends the app back to the setup
  /// screen instead of leaving a now-unreachable session on screen.
  Future<void> _checkCameraStillReachable() async {
    if (_stage == _Stage.idle || _stage == _Stage.connecting) return;

    final ssid = await NetworkBinding.currentWifiSsid();
    if (!mounted || _stage == _Stage.idle || _stage == _Stage.connecting) {
      return;
    }

    if (ssid != null && _looksLikeCameraSsid(ssid)) {
      _wifiMissCount = 0;
      return;
    }

    // A single missed read can just be a flaky SSID lookup; two in a row,
    // five seconds apart, is the camera actually gone.
    _wifiMissCount++;
    if (_wifiMissCount < 2) return;
    _wifiMissCount = 0;
    await _handleCameraLost();
  }

  Future<void> _handleCameraLost() async {
    if (_stage == _Stage.idle) return;
    if (_stage == _Stage.transferring) _transfer.cancel();
    await _reset(
      statusOverride: "Camera Wi-Fi lost — it may have turned off. "
          'Reconnect once it is back on.',
    );
  }

  Future<void> _loadDestinationFolder() async {
    final name = await DestinationFolder.currentName();
    if (!mounted) return;
    setState(() => _destinationFolderName = name);
  }

  Future<void> _pickDestinationFolder() async {
    final result = await DestinationFolder.pick();
    if (!mounted) return;
    // Re-read from Android: the pick Result can be lost if the activity was
    // recreated while the system folder UI was up, even though the URI was
    // still persisted — currentName is the source of truth for saves.
    final name = await DestinationFolder.currentName() ?? result.name;
    if (!mounted) return;
    setState(() => _destinationFolderName = name);
  }

  Future<void> _clearDestinationFolder() async {
    await DestinationFolder.clear();
    if (!mounted) return;
    setState(() => _destinationFolderName = null);
  }

  Future<void> _restoreCredentials() async {
    final saved = await SavedWifiCredentials.load();
    if (!mounted) return;
    setState(() {
      _rememberedSsid = saved.ssid;
      _selectedSsid = saved.ssid;
      _autoConnect = saved.autoConnect;
      if (saved.ssid != null && saved.ssid!.isNotEmpty) {
        _ssidController.text = saved.ssid!;
      }
      if (saved.password != null) {
        _passwordController.text = saved.password!;
      }
    });
    await _scanNetworks();
  }

  Future<void> _setAutoConnect(bool value) async {
    setState(() => _autoConnect = value);
    await SavedWifiCredentials.saveAutoConnect(value);
  }

  /// The remembered network if this scan sees it, or the sole camera network
  /// in range when there is no remembered one to prefer.
  String? _matchedCameraSsid(List<String> cameras) {
    if (cameras.contains(_rememberedSsid)) return _rememberedSsid;
    if (cameras.length == 1) return cameras.single;
    return null;
  }

  Future<void> _scanNetworks() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _error = null;
    });

    try {
      final scan = await NetworkBinding.scanCameraWifi();
      if (!mounted) return;

      final matched = _matchedCameraSsid(scan.cameras);
      setState(() {
        _cameraNetworks = scan.cameras;
        _allNetworks = scan.all;
        _scanProblem = scan.problem;
        _scanning = false;

        // Prefer an in-range remembered network, then a sole match. A remembered
        // name that this scan missed is kept: the camera may still be waking, and
        // the join can proceed without a fresh sighting.
        if (!scan.cameras.contains(_selectedSsid) && matched != null) {
          _selectedSsid = matched;
        }
        if (_selectedSsid != null &&
            _selectedSsid!.isNotEmpty &&
            _ssidController.text.trim().isEmpty) {
          _ssidController.text = _selectedSsid!;
        }

        // Forget a stale auto-connect attempt once its network drops out of
        // range, so the same camera can be auto-joined again next time it
        // shows up — after a password fix, or just being turned back on.
        if (_autoConnectedSsid != null &&
            !scan.cameras.contains(_autoConnectedSsid)) {
          _autoConnectedSsid = null;
        }
      });

      final shouldAutoConnect = _autoConnect &&
          _stage == _Stage.idle &&
          matched != null &&
          matched != _autoConnectedSsid &&
          _passwordController.text.isNotEmpty;
      if (shouldAutoConnect) {
        _autoConnectedSsid = matched;
        unawaited(_connect());
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = e.message ?? 'Wi-Fi scan failed.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    _autoScanTimer?.cancel();
    _connectionWatchdog?.cancel();
    _listing?.cancel();
    _hostController.dispose();
    _ssidController.dispose();
    _passwordController.dispose();
    _scrollController.dispose();
    _progress.dispose();
    _client?.close();
    _transfer.close();
    // Best-effort: the widget is going away, so there is no UI to await.
    NetworkBinding.disconnectWifi();
    super.dispose();
  }

  int get _transferable => _items.where((i) => !i.isRawOnly).length;

  Iterable<CameraItem> get _transferableItems =>
      _items.where((i) => !i.isRawOnly);

  void _toggle(CameraItem item) => setState(() {
        if (!_selected.remove(item.id)) _selected.add(item.id);
      });

  void _toggleDay(TimelineSection section) => setState(() {
        final ids =
            section.items.where((i) => !i.isRawOnly).map((i) => i.id).toSet();
        if (_selected.containsAll(ids)) {
          _selected.removeAll(ids);
        } else {
          _selected.addAll(ids);
        }
      });

  void _selectAll() => setState(
        () => _selected.addAll(_transferableItems.map((i) => i.id)),
      );

  void _clearSelection() => setState(_selected.clear);

  /// Addresses worth trying, best guess first.
  ///
  /// Which subnet the camera picks varies between bodies and firmware, so the
  /// detected gateway is preferred over any hard-coded address.
  Future<List<String>> _candidateHosts() async {
    final candidates = <String>[];
    if (_autoDetect) {
      final gateway = await NetworkBinding.wifiGateway();
      if (gateway != null && gateway.isNotEmpty) candidates.add(gateway);
    }
    final typed = _hostController.text.trim();
    if (typed.isNotEmpty) candidates.add(typed);
    candidates.add(SonyCameraClient.defaultHost);

    final seen = <String>{};
    return candidates.where(seen.add).toList();
  }

  Future<({String host, String name})?> _findCamera(List<String> hosts) async {
    for (final host in hosts) {
      if (!mounted) return null;
      setState(() => _status = 'Trying $host…');

      // Short timeout: a wrong address should not hold up the next candidate.
      final probe =
          SonyCameraClient(host: host, timeout: const Duration(seconds: 6));
      try {
        return (host: host, name: await probe.probe());
      } on CameraException {
        continue;
      } finally {
        probe.close();
      }
    }
    return null;
  }

  Future<void> _connect() async {
    _listing?.cancel();
    _listing = null;
    setState(() {
      _stage = _Stage.connecting;
      _error = null;
      _loading = false;
      _items = const [];
      _sections = const [];
      _selected.clear();
      _outcomes.clear();
      _status = 'Creating temporary camera Wi-Fi connection…';
    });

    final typedSsid = _ssidController.text.trim();
    final ssid =
        typedSsid.isNotEmpty ? typedSsid : (_selectedSsid?.trim() ?? '');
    final password = _passwordController.text;

    final currentSsid = await NetworkBinding.currentWifiSsid();
    final alreadyOnCamera =
        currentSsid != null && _looksLikeCameraSsid(currentSsid);

    // The temporary app-owned connection is released on Disconnect.
    if (password.isNotEmpty && !alreadyOnCamera) {
      final joined = await NetworkBinding.joinCameraWifi(
        ssid: ssid,
        password: password,
      );
      if (!mounted) return;
      if (!joined.ok) {
        setState(() {
          _stage = _Stage.idle;
          _status = '';
          _error = joined.message ?? 'Could not join the camera Wi-Fi.';
        });
        return;
      }
      await SavedWifiCredentials.save(
        ssid: ssid.isNotEmpty ? ssid : (_rememberedSsid ?? ''),
        password: password,
      );
      _rememberedSsid = ssid.isNotEmpty ? ssid : _rememberedSsid;
      if (ssid.isNotEmpty) {
        _selectedSsid = ssid;
        _ssidController.text = ssid;
      }
    } else {
      final bound = await NetworkBinding.bindToWifi();
      if (!mounted) return;
      if (!bound) {
        setState(() => _status = 'Could not pin to Wi-Fi; trying anyway…');
      } else if (password.isNotEmpty && ssid.isNotEmpty) {
        await SavedWifiCredentials.save(ssid: ssid, password: password);
        _rememberedSsid = ssid;
      }
    }

    final hosts = await _candidateHosts();
    if (!mounted) return;

    final found = await _findCamera(hosts);
    if (!mounted) return;

    if (found == null) {
      await NetworkBinding.disconnectWifi();
      if (!mounted) return;
      setState(() {
        _stage = _Stage.idle;
        _status = '';
        _error = 'No camera answered on ${hosts.join(', ')}.\n\n'
            '1. On the camera: Send to Smartphone must still be waiting.\n'
            '2. On the tablet: join the DIRECT- Wi-Fi shown on the camera.\n'
            '3. Come back and tap Connect again.';
      });
      return;
    }

    _hostController.text = found.host;
    _client?.close();
    final client = SonyCameraClient(host: found.host);
    _client = client;

    try {
      setState(() {
        _cameraName = found.name;
        _status = 'Asking the camera to start sending…';
      });
      // Absent in "Select on Smartphone" mode; it only drives the camera's
      // own display, so browsing goes ahead either way.
      await client.transferStart();

      final linkInfo = await NetworkBinding.wifiLinkInfo();
      if (!mounted) return;

      setState(() {
        _linkInfo = linkInfo;
        _stage = _Stage.connected;
        _loading = true;
        _status = 'Loading newest shots…';
      });

      _startListing(client);
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.idle;
        _error = e.message;
        _status = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.idle;
        _error = '$e';
        _status = '';
      });
    }
  }

  static bool _looksLikeCameraSsid(String ssid) {
    final upper = ssid.toUpperCase();
    return upper.startsWith('DIRECT-') ||
        upper.contains('ILCE') ||
        upper.contains('DSC-') ||
        upper.contains('ZV-') ||
        (upper.contains('SONY') && upper.contains('CAM'));
  }

  /// Appends shots as the camera hands them over, so the timeline is usable — and
  /// transfers can be started — long before the whole card has been enumerated.
  void _startListing(SonyCameraClient client) {
    _listing?.cancel();
    _listing = client.browse().listen(
      (page) {
        if (!mounted) return;
        setState(() {
          _items = [..._items, ...page];
          _sections = groupIntoTimeline(_items);
          _status = 'Newest first · ${_items.length} loaded so far…';
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          // Whatever arrived before the failure is still worth offering.
          _error = e is CameraException ? e.message : '$e';
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _status = _items.isEmpty
              ? 'Camera connected, but it is offering no shots.'
              : 'Tap shots to choose what to transfer.';
        });
      },
      cancelOnError: true,
    );
  }

  Future<void> _downloadSelected() async {
    final queue =
        _transferableItems.where((i) => _selected.contains(i.id)).toList();
    if (queue.isEmpty) return;

    // If the camera drops off mid-transfer, the connection watchdog resets
    // straight to the setup screen; this lets the loop below notice and stop
    // instead of overwriting that with its own "finished" summary.
    final session = _sessionId;

    _transfer.resetCancel();
    setState(() {
      _stage = _Stage.transferring;
      _done = 0;
      _queueLength = queue.length;
      _error = null;
      _status = 'Transferring…';
    });
    unawaited(
      NetworkBinding.wifiLinkInfo().then((info) {
        if (mounted) setState(() => _linkInfo = info);
      }),
    );

    final stream = _transfer.transferAll(
      queue,
      onProgress: (progress) => _progress.value = progress,
    );

    await for (final result in stream) {
      if (!mounted || _sessionId != session) return;

      // A skipped shot downloads nothing, so no progress arrives for it and the
      // bar would otherwise sit at the previous shot's 100%.
      if (result.outcome == TransferOutcome.skippedExisting ||
          result.outcome == TransferOutcome.skippedRaw) {
        _progress.value = null;
      }

      setState(() {
        _outcomes[result.item.id] = result.outcome;
        _done++;
        if (result.outcome == TransferOutcome.failed) {
          _status = '${result.item.fileName}: ${result.detail}';
        }
      });
    }
    if (!mounted || _sessionId != session) return;

    final cancelled = _transfer.isCancelled;
    final saved =
        _outcomes.values.where((o) => o == TransferOutcome.saved).length;
    final failed =
        _outcomes.values.where((o) => o == TransferOutcome.failed).length;

    final rate = '${formatBytes(_transfer.averageBytesPerSecond.round())}/s';
    _progress.value = null;
    setState(() {
      _stage = _Stage.finished;
      // The batch is dealt with, so start the next pick from a clean slate.
      // A cancelled run keeps its selection — the natural follow-up there is
      // resuming, not re-picking.
      if (!cancelled) _selected.clear();
      _status = cancelled
          ? 'Cancelled after $saved saved, averaging $rate.'
          : 'Saved $saved of ${queue.length}'
              '${failed > 0 ? ', $failed failed' : ''}, averaging $rate.';
    });

    if (!cancelled) await _client?.transferEnd();
  }

  /// Returns to the setup screen. [statusOverride] replaces the usual
  /// "Left the camera Wi-Fi" message — used when this was not a manual
  /// Disconnect tap but the camera dropping off on its own.
  Future<void> _reset({String? statusOverride}) async {
    // Lets a transfer loop or connect attempt still in flight recognise it
    // has been superseded and stop applying its own state on top of this.
    _sessionId++;

    _listing?.cancel();
    _listing = null;

    // Release the camera from "Sending…" before dropping its Wi-Fi.
    final client = _client;
    _client = null;
    if (client != null) {
      await client.transferEnd();
      client.close();
    }

    final left = await NetworkBinding.disconnectWifi();
    if (!mounted) return;

    setState(() {
      _stage = _Stage.idle;
      _loading = false;
      _items = const [];
      _sections = const [];
      _selected.clear();
      _outcomes.clear();
      _cameraName = null;
      _error = null;
      _status = statusOverride ??
          switch (left) {
            WifiDisconnectResult.released => 'Left the camera Wi-Fi.',
            WifiDisconnectResult.openedSettings =>
              'Open the Wi-Fi panel and leave the DIRECT- network — Android will not '
                  'let the app drop a network you joined in Settings.',
            WifiDisconnectResult.failed =>
              'Disconnected from the camera, but the phone may still be on its Wi-Fi. '
                  'Leave the DIRECT- network in Android Wi-Fi settings.',
          };
      _done = 0;
    });
    _progress.value = null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.onBack == null
            ? null
            : BackButton(onPressed: widget.onBack),
        title: const Text('Sony Transfer'),
        actions: [
          if (_sections.isNotEmpty && _stage != _Stage.transferring) ...[
            IconButton(
              tooltip: 'Select all',
              onPressed:
                  _selected.length == _transferable ? null : _selectAll,
              icon: const Icon(Icons.select_all),
            ),
            IconButton(
              tooltip: 'Clear selection',
              onPressed: _selected.isEmpty ? null : _clearSelection,
              icon: const Icon(Icons.deselect),
            ),
          ],
          if (_stage == _Stage.connected ||
              _stage == _Stage.finished ||
              _stage == _Stage.transferring)
            IconButton(
              tooltip: 'Disconnect',
              onPressed: _stage == _Stage.transferring ? null : _reset,
              icon: const Icon(Icons.link_off),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              // Own controller: HomeShell keeps album/Wi-Fi/USB in an
              // IndexedStack, and sharing PrimaryScrollController across those
              // offstage scroll views stops the visible timeline from moving.
              controller: _scrollController,
              primary: false,
              slivers: [
                SliverToBoxAdapter(
                  child: _StatusPanel(
                    stage: _stage,
                    cameraName: _cameraName,
                    hostController: _hostController,
                    ssidController: _ssidController,
                    passwordController: _passwordController,
                    cameraNetworks: _cameraNetworks,
                    allNetworks: _allNetworks,
                    scanProblem: _scanProblem,
                    showAllNetworks: _showAllNetworks,
                    onShowAllNetworks: () =>
                        setState(() => _showAllNetworks = !_showAllNetworks),
                    selectedSsid: _selectedSsid,
                    scanning: _scanning,
                    onSelectSsid: (ssid) => setState(() {
                      _selectedSsid = ssid;
                      if (_ssidController.text != ssid) {
                        _ssidController.value = TextEditingValue(
                          text: ssid,
                          selection:
                              TextSelection.collapsed(offset: ssid.length),
                        );
                      }
                    }),
                    onSsidEdited: (ssid) =>
                        setState(() => _selectedSsid = ssid),
                    onScan: _scanNetworks,
                    onOpenWifiSettings: NetworkBinding.openWifiSettings,
                    onOpenLocationSettings:
                        NetworkBinding.openLocationSettings,
                    onOpenAppSettings: NetworkBinding.openAppSettings,
                    status: _status,
                    error: _error,
                    destinationFolderName: _destinationFolderName,
                    onPickDestinationFolder: _pickDestinationFolder,
                    onClearDestinationFolder: _clearDestinationFolder,
                    itemCount: _items.length,
                    transferable: _transferable,
                    selectedCount: _selected.length,
                    autoDetect: _autoDetect,
                    onAutoDetectChanged: (value) =>
                        setState(() => _autoDetect = value),
                    autoConnect: _autoConnect,
                    onAutoConnectChanged: _setAutoConnect,
                    onConnect: () => _connect(),
                  ),
                ),
                const SliverToBoxAdapter(child: Divider(height: 1)),
                if (_sections.isEmpty && _loading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_sections.isEmpty)
                  const SliverToBoxAdapter(child: _Instructions())
                else
                  ...TimelineView.slivers(
                    sections: _sections,
                    selected: _selected,
                    outcomes: _outcomes,
                    loadingMore: _loading,
                    onToggle: _toggle,
                    onToggleDay: _toggleDay,
                  ),
              ],
            ),
          ),
          TransferBottomBar(
            visible: _stage != _Stage.idle && _stage != _Stage.connecting,
            transferring: _stage == _Stage.transferring,
            selectedCount: _selected.length,
            queueLength: _queueLength,
            done: _done,
            progress: _progress,
            linkInfo: _linkInfo,
            onDownload: _downloadSelected,
            onCancel: _transfer.cancel,
          ),
        ],
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.stage,
    required this.cameraName,
    required this.hostController,
    required this.ssidController,
    required this.passwordController,
    required this.cameraNetworks,
    required this.allNetworks,
    required this.scanProblem,
    required this.showAllNetworks,
    required this.onShowAllNetworks,
    required this.selectedSsid,
    required this.scanning,
    required this.onSelectSsid,
    required this.onSsidEdited,
    required this.onScan,
    required this.onOpenWifiSettings,
    required this.onOpenLocationSettings,
    required this.onOpenAppSettings,
    required this.status,
    required this.error,
    required this.destinationFolderName,
    required this.onPickDestinationFolder,
    required this.onClearDestinationFolder,
    required this.itemCount,
    required this.transferable,
    required this.selectedCount,
    required this.autoDetect,
    required this.onAutoDetectChanged,
    required this.autoConnect,
    required this.onAutoConnectChanged,
    required this.onConnect,
  });

  final _Stage stage;
  final String? cameraName;
  final TextEditingController hostController;
  final TextEditingController ssidController;
  final TextEditingController passwordController;
  final List<String> cameraNetworks;
  final List<String> allNetworks;
  final WifiScanProblem? scanProblem;
  final bool showAllNetworks;
  final VoidCallback onShowAllNetworks;
  final String? selectedSsid;
  final bool scanning;
  final ValueChanged<String> onSelectSsid;
  final ValueChanged<String> onSsidEdited;
  final VoidCallback onScan;
  final VoidCallback onOpenWifiSettings;
  final VoidCallback onOpenLocationSettings;
  final VoidCallback onOpenAppSettings;
  final String status;
  final String? error;

  /// Folder saves are redirected to, or null when using the default Photos
  /// album.
  final String? destinationFolderName;
  final VoidCallback onPickDestinationFolder;
  final VoidCallback onClearDestinationFolder;
  final int itemCount;
  final int transferable;
  final int selectedCount;
  final bool autoDetect;
  final ValueChanged<bool> onAutoDetectChanged;

  /// Whether a sighting of the remembered camera network joins automatically.
  final bool autoConnect;
  final ValueChanged<bool> onAutoConnectChanged;
  final VoidCallback onConnect;

  List<String> _chips() =>
      showAllNetworks && cameraNetworks.isEmpty ? allNetworks : cameraNetworks;

  /// Scanning fails quietly on Android for several fixable reasons; naming the
  /// likely one beats showing an empty list.
  String _scanHint() => switch (scanProblem) {
        WifiScanProblem.wifiOff =>
          'Wi-Fi is off. Turn it on, then Scan again.',
        WifiScanProblem.permissionDenied =>
          'Scanning needs Nearby devices / Location permission. Grant it below, '
              'or type the network name from the camera screen.',
        WifiScanProblem.locationOff =>
          'Android returns no Wi-Fi scan results while Location is switched off. '
              'Turn Location on, or type the network name from the camera.',
        WifiScanProblem.throttled =>
          'Android is rate-limiting Wi-Fi scans. Wait a moment and Scan again.',
        WifiScanProblem.noneFound =>
          'No camera network in range. Start Send to Smartphone on the camera, '
              'then Scan — or type the DIRECT- name from the camera screen.',
        WifiScanProblem.unsupported => 'Scanning is only available on Android.',
        null => 'Tap Scan once the camera is showing its DIRECT- network, '
            'or type that name below.',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = stage == _Stage.connecting;
    final connected = stage != _Stage.idle && stage != _Stage.connecting;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                connected ? Icons.photo_camera : Icons.photo_camera_outlined,
                color: connected
                    ? theme.colorScheme.primary
                    : theme.disabledColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  cameraName ?? 'Not connected',
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!connected)
                FilledButton.icon(
                  onPressed: busy ? null : onConnect,
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_find),
                  label: Text(busy ? 'Connecting' : 'Connect'),
                ),
            ],
          ),
          if (!connected) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Camera Wi-Fi',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                TextButton.icon(
                  onPressed: busy || scanning ? null : onScan,
                  icon: scanning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(scanning ? 'Scanning' : 'Scan'),
                ),
              ],
            ),
            if (cameraNetworks.isEmpty && !scanning) ...[
              Text(
                _scanHint(),
                style:
                    theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
              Wrap(
                spacing: 8,
                children: [
                  if (scanProblem == WifiScanProblem.locationOff)
                    TextButton(
                      onPressed: busy ? null : onOpenLocationSettings,
                      child: const Text('Open Location settings'),
                    ),
                  if (scanProblem == WifiScanProblem.permissionDenied)
                    TextButton(
                      onPressed: busy ? null : onOpenAppSettings,
                      child: const Text('Open app settings'),
                    ),
                  TextButton(
                    onPressed: busy ? null : onOpenWifiSettings,
                    child: const Text('Open Wi-Fi settings'),
                  ),
                  if (allNetworks.isNotEmpty)
                    TextButton(
                      onPressed: onShowAllNetworks,
                      child: Text(
                        showAllNetworks
                            ? 'Hide other networks'
                            : 'Show all ${allNetworks.length} networks',
                      ),
                    ),
                ],
              ),
            ],
            if (_chips().isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final ssid in _chips())
                    ChoiceChip(
                      label: Text(ssid, overflow: TextOverflow.ellipsis),
                      selected: selectedSsid == ssid,
                      onSelected: busy ? null : (_) => onSelectSsid(ssid),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            TextField(
              controller: ssidController,
              enabled: !busy,
              textInputAction: TextInputAction.next,
              onChanged: (value) => onSsidEdited(value.trim()),
              decoration: const InputDecoration(
                labelText: 'Camera Wi-Fi name (SSID)',
                helperText: 'Copied from the camera screen if Scan finds nothing',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            _PasswordField(
              controller: passwordController,
              enabled: !busy,
              onSubmitted: onConnect,
            ),
            SwitchListTile(
              value: autoConnect,
              onChanged: onAutoConnectChanged,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-connect'),
              subtitle: const Text(
                'Joins as soon as this Wi-Fi and its saved password are found',
              ),
            ),
            SwitchListTile(
              value: autoDetect,
              onChanged: busy ? null : onAutoDetectChanged,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Detect camera address'),
              subtitle: const Text('Uses the gateway of the joined Wi-Fi'),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: hostController,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: autoDetect ? 'Fallback address' : 'Camera address',
                helperText: autoDetect
                    ? 'Tried only if detection finds nothing'
                    : 'Default for Send to Smartphone mode',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          if (connected) ...[
            const SizedBox(height: 4),
            Text(
              'Connected at ${hostController.text}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.folder_outlined, size: 16, color: theme.hintColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    destinationFolderName == null
                        ? 'Saving to the Photos app (SonyTransfer album)'
                        : 'Saving to "$destinationFolderName"',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: onPickDestinationFolder,
                  style: _compactButtonStyle,
                  child: Text(
                    destinationFolderName == null ? 'Choose folder' : 'Change',
                  ),
                ),
                if (destinationFolderName != null)
                  TextButton(
                    onPressed: onClearDestinationFolder,
                    style: _compactButtonStyle,
                    child: const Text('Reset'),
                  ),
              ],
            ),
          ],
          if (connected && itemCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              '$itemCount shots · $transferable as JPEG · $selectedCount selected',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              'Tap a shot to see it big · corner box selects',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
          if (status.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(status, style: theme.textTheme.bodySmall),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                error!,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PasswordField extends StatefulWidget {
  const _PasswordField({
    required this.controller,
    required this.enabled,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSubmitted;

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscured,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => widget.onSubmitted(),
      decoration: InputDecoration(
        labelText: 'Camera Wi-Fi password',
        helperText: 'Shown on the camera · remembered after Connect',
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: _obscured ? 'Show password' : 'Hide password',
          onPressed: widget.enabled
              ? () => setState(() => _obscured = !_obscured)
              : null,
          icon: Icon(
            _obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          ),
        ),
      ),
    );
  }
}

class _Instructions extends StatelessWidget {
  const _Instructions();

  static const List<String> _steps = [
    'On the camera open MENU → Network → Send to Smartphone Func. → Send to '
        'Smartphone.',
    'Choose "Select on Smartphone" to expose the whole card, or pick individual '
        'shots on the camera.',
    'Turn Location on (Android needs it to list Wi-Fi names), tap Scan, and pick '
        'the DIRECT- network — or type that name from the camera screen.',
    'Enter the password and tap Connect. Approve Android’s temporary connection '
        'prompt; the camera network is not saved and is released on Disconnect.',
    'Turn mobile data off if the transfer stalls — Android prefers a route with '
        'internet.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Getting the camera ready', style: theme.textTheme.titleSmall),
          const SizedBox(height: 16),
          for (var i = 0; i < _steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(_steps[i], style: theme.textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'Raw files are listed but cannot be transferred: over this '
            'protocol the camera only serves embedded preview JPEGs for '
            'ARW, never the raw data. Use the SD card for those.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}

