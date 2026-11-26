import 'package:flutter/material.dart';
import 'package:image_album/image_album.dart';

import '../services/transfer_service.dart';

/// The app's home page: an album of the shots this app has already
/// transferred off the camera.
///
/// The grid itself lives in the `image_album` library. This screen only
/// resolves the transfer cache folder and hands that path over, then adds
/// the camera actions and the copy that is specific to this app.
class AlbumScreen extends StatefulWidget {
  const AlbumScreen({
    super.key,
    required this.onOpenTransfer,
    this.onOpenUsbTransfer,
    this.onOpenMonitor,
    TransferService? transferService,
  }) : _transferService = transferService;

  /// Brings up the Wi-Fi camera transfer flow. [HomeShell] switches to its
  /// kept-alive [TransferScreen] rather than this screen pushing a route,
  /// so that coming back does not dispose the flow and cut the connection.
  final VoidCallback onOpenTransfer;

  /// Brings up the USB cable transfer flow (Mass Storage + Multi LUN).
  final VoidCallback? onOpenUsbTransfer;

  /// Live view plus a background copy of each new JPEG.
  final VoidCallback? onOpenMonitor;

  /// Overridable for tests, which have no platform channels to ask for the
  /// real external storage path.
  final TransferService? _transferService;

  @override
  State<AlbumScreen> createState() => AlbumScreenState();
}

class AlbumScreenState extends State<AlbumScreen> {
  late final TransferService _transfer =
      widget._transferService ?? TransferService();
  final GlobalKey<ImageAlbumState> _albumKey = GlobalKey<ImageAlbumState>();

  String? _path;
  String? _pathError;

  @override
  void initState() {
    super.initState();
    _resolvePath();
  }

  @override
  void dispose() {
    _transfer.close();
    super.dispose();
  }

  /// Re-scans the cache folder; called by [HomeShell] when returning from a
  /// transfer, which may have just landed new shots.
  void reload() => _albumKey.currentState?.reload();

  Future<void> _resolvePath() async {
    try {
      final dir = await _transfer.destinationDirectory();
      if (!mounted) return;
      setState(() {
        _path = dir.path;
        _pathError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _pathError = '$e');
    }
  }

  List<Widget> get _actions => [
        if (widget.onOpenMonitor != null)
          IconButton(
            tooltip: 'Live monitor',
            onPressed: widget.onOpenMonitor,
            icon: const Icon(Icons.live_tv),
          ),
        if (widget.onOpenUsbTransfer != null)
          IconButton(
            tooltip: 'USB cable transfer',
            onPressed: widget.onOpenUsbTransfer,
            icon: const Icon(Icons.usb),
          ),
        IconButton(
          tooltip: 'Connect camera',
          onPressed: widget.onOpenTransfer,
          icon: const Icon(Icons.photo_camera_outlined),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final path = _path;
    // The library needs a concrete directory. Until the cache path is known
    // (or the lookup failed), keep the same app bar so Connect camera is
    // available on the first frame.
    if (path == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Sony Transfer'),
          actions: _actions,
        ),
        body: _pathError == null
            ? const Center(child: CircularProgressIndicator())
            : _PathError(message: _pathError!, onRetry: _resolvePath),
      );
    }

    return ImageAlbum(
      key: _albumKey,
      path: path,
      title: const Text('Sony Transfer'),
      actions: _actions,
      empty: _EmptyAlbum(
        onConnect: widget.onOpenTransfer,
        onMonitor: widget.onOpenMonitor,
      ),
      countLabel: (count) => '$count transferred',
      confirmDelete: _confirmDelete,
    );
  }
}

Future<bool> _confirmDelete(BuildContext context, int count) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        count == 1 ? 'Delete 1 photo?' : 'Delete $count photos?',
      ),
      content: const Text(
        'This removes them from this album only. Copies already saved to '
        'the Photos app or your chosen folder are kept. Deleted shots can '
        'be transferred from the camera again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

class _EmptyAlbum extends StatelessWidget {
  const _EmptyAlbum({required this.onConnect, this.onMonitor});

  final VoidCallback onConnect;
  final VoidCallback? onMonitor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.photo_library_outlined,
            size: 56,
            color: theme.disabledColor,
          ),
          const SizedBox(height: 16),
          Text(
            'No photos transferred yet',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Open the live monitor to watch the camera and copy each new '
            'photo while you keep shooting, or connect and pick shots to copy.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 20),
          if (onMonitor != null) ...[
            FilledButton.icon(
              onPressed: onMonitor,
              icon: const Icon(Icons.live_tv),
              label: const Text('Live monitor'),
            ),
            const SizedBox(height: 8),
          ],
          FilledButton.icon(
            onPressed: onConnect,
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('Connect camera'),
          ),
        ],
      ),
    );
  }
}

class _PathError extends StatelessWidget {
  const _PathError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 56,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            const Text('Could not load the album', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
