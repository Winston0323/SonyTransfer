import 'package:flutter/material.dart';

import '../services/transfer_service.dart';
import 'album_screen.dart';
import 'transfer_screen.dart';

/// The app's root: the album and the camera transfer flow live side by side
/// in an [IndexedStack], so leaving the transfer screen for the album merely
/// hides it. Pushing it as a route instead would dispose it on pop, and its
/// teardown drops the camera's Wi-Fi — going back to the album would cut the
/// connection.
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

  bool _showingTransfer = false;

  /// The transfer screen is only built once it is first opened, so launching
  /// the app to look at the album does not start Wi-Fi scanning.
  bool _transferOpened = false;

  void _openTransfer() {
    setState(() {
      _transferOpened = true;
      _showingTransfer = true;
    });
  }

  void _showAlbum() {
    setState(() => _showingTransfer = false);
    // New shots may well have landed while the transfer screen was up.
    _albumKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    // The system back gesture should also return to the album rather than
    // leave the app while the transfer screen is up.
    return PopScope(
      canPop: !_showingTransfer,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showAlbum();
      },
      child: IndexedStack(
        index: _showingTransfer ? 1 : 0,
        children: [
          AlbumScreen(
            key: _albumKey,
            transferService: widget.transferService,
            onOpenTransfer: _openTransfer,
          ),
          if (_transferOpened)
            TransferScreen(onBack: _showAlbum)
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}
