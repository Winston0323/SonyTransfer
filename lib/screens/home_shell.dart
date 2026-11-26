import 'dart:async';

import 'package:flutter/material.dart';

import '../services/transfer_service.dart';
import '../services/usb_camera.dart';
import 'album_screen.dart';
import 'monitor_screen.dart';
import 'transfer_screen.dart';
import 'usb_transfer_screen.dart';

enum _Pane { album, wifi, usb, monitor }

/// The app's root: the album and the camera transfer flows live side by side
/// in an [IndexedStack], so leaving a transfer screen for the album merely
/// hides it. Pushing a route instead would dispose that state — for Wi-Fi that
/// drops the camera network; for USB it would close the mass-storage handles.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.transferService});

  /// Passed through to [AlbumScreen]; overridable for tests, which have no
  /// platform channels to ask for the real external storage path.
  final TransferService? transferService;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final GlobalKey<AlbumScreenState> _albumKey = GlobalKey<AlbumScreenState>();

  _Pane _pane = _Pane.album;

  /// Built lazily so launching the app to look at the album does not start
  /// Wi-Fi scanning or open USB mass-storage handles.
  bool _wifiOpened = false;
  bool _usbOpened = false;
  bool _monitorOpened = false;

  StreamSubscription<String>? _usbEvents;

  @override
  void initState() {
    super.initState();
    _usbEvents = UsbCamera.events.listen(_onUsbEvent);
    // Camera may already be plugged in before the app opened.
    unawaited(_checkUsbAlreadyAttached());
  }

  @override
  void dispose() {
    _usbEvents?.cancel();
    super.dispose();
  }

  Future<void> _checkUsbAlreadyAttached() async {
    final status = await UsbCamera.status();
    if (!mounted) return;
    if (status.attached) _openUsb();
  }

  void _onUsbEvent(String event) {
    if (!mounted) return;
    if (event == 'attached') {
      _openUsb();
    } else if (event == 'detached') {
      // Cable pulled — drop the USB pane so its mass-storage handles close,
      // and leave a stale card list off the screen. Next plug builds fresh.
      if (_usbOpened || _pane == _Pane.usb) {
        setState(() {
          _usbOpened = false;
          if (_pane == _Pane.usb) _pane = _Pane.album;
        });
        _albumKey.currentState?.reload();
      }
    }
  }

  void _openWifi() {
    setState(() {
      _wifiOpened = true;
      _pane = _Pane.wifi;
    });
  }

  void _openUsb() {
    setState(() {
      _usbOpened = true;
      _pane = _Pane.usb;
    });
  }

  void _openMonitor() {
    setState(() {
      _monitorOpened = true;
      _pane = _Pane.monitor;
    });
  }

  void _showAlbum() {
    setState(() => _pane = _Pane.album);
    _albumKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final showingTransfer = _pane != _Pane.album;
    return PopScope(
      canPop: !showingTransfer,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showAlbum();
      },
      child: IndexedStack(
        index: switch (_pane) {
          _Pane.album => 0,
          _Pane.wifi => 1,
          _Pane.usb => 2,
          _Pane.monitor => 3,
        },
        children: [
          AlbumScreen(
            key: _albumKey,
            transferService: widget.transferService,
            onOpenTransfer: _openWifi,
            onOpenUsbTransfer: _openUsb,
            onOpenMonitor: _openMonitor,
          ),
          if (_wifiOpened)
            TransferScreen(onBack: _showAlbum)
          else
            const SizedBox.shrink(),
          if (_usbOpened)
            UsbTransferScreen(onBack: _showAlbum)
          else
            const SizedBox.shrink(),
          if (_monitorOpened)
            MonitorScreen(
              onBack: _showAlbum,
              active: _pane == _Pane.monitor,
              onPhotoSaved: () => _albumKey.currentState?.reload(),
              transferService: widget.transferService,
            )
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}
