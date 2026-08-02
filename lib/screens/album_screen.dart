import 'package:flutter/material.dart';

import '../models/transferred_photo.dart';
import '../services/transfer_service.dart';
import '../widgets/local_preview_page.dart';

/// The app's home page: an album of the shots this app has already
/// transferred off the camera — not everything sitting in the Photos album
/// or a chosen destination folder, which may hold unrelated pictures too.
class AlbumScreen extends StatefulWidget {
  const AlbumScreen({
    super.key,
    required this.onOpenTransfer,
    TransferService? transferService,
  }) : _transferService = transferService;

  /// Brings up the camera transfer flow. [HomeShell] switches to its
  /// kept-alive [TransferScreen] rather than this screen pushing a route,
  /// so that coming back does not dispose the flow and cut the connection.
  final VoidCallback onOpenTransfer;

  /// Overridable for tests, which have no platform channels to ask for the
  /// real external storage path.
  final TransferService? _transferService;

  @override
  State<AlbumScreen> createState() => AlbumScreenState();
}

class AlbumScreenState extends State<AlbumScreen> {
  late final TransferService _transfer =
      widget._transferService ?? TransferService();

  List<TransferredDaySection> _sections = const [];
  bool _loading = true;
  String? _error;

  /// Shots picked for deletion, by [TransferredPhoto.id]. Non-empty is what
  /// puts the screen in selection mode: tap then toggles instead of opening
  /// the preview, and the app bar switches to the delete actions.
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _transfer.close();
    super.dispose();
  }

  /// Re-scans the cache folder; called by [HomeShell] when returning from the
  /// transfer flow, which may have just landed new shots.
  void reload() => _load();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final photos = await _transfer.listTransferred();
      if (!mounted) return;
      setState(() {
        _sections = groupTransferredByDay(photos);
        // Whatever was selected may no longer exist after a re-scan.
        _selected.removeWhere(
          (id) => !photos.any((photo) => photo.id == id),
        );
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _openPreview(List<TransferredPhoto> flatPhotos, TransferredPhoto photo) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalPreviewPage(
          photos: flatPhotos,
          initialIndex: flatPhotos.indexOf(photo),
        ),
      ),
    );
  }

  void _toggle(TransferredPhoto photo) {
    setState(() {
      if (!_selected.remove(photo.id)) _selected.add(photo.id);
    });
  }

  void _selectAll(List<TransferredPhoto> flatPhotos) {
    setState(() => _selected.addAll(flatPhotos.map((photo) => photo.id)));
  }

  Future<void> _deleteSelected(List<TransferredPhoto> flatPhotos) async {
    final picked =
        flatPhotos.where((photo) => _selected.contains(photo.id)).toList();
    if (picked.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          picked.length == 1
              ? 'Delete 1 photo?'
              : 'Delete ${picked.length} photos?',
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
    if (confirmed != true || !mounted) return;

    await _transfer.deleteTransferred(picked);
    if (!mounted) return;
    setState(() => _selected.clear());
    await _load();
  }

  int get _totalPhotos =>
      _sections.fold(0, (sum, section) => sum + section.photos.length);

  @override
  Widget build(BuildContext context) {
    final flatPhotos = [
      for (final section in _sections) ...section.photos,
    ];
    final selecting = _selected.isNotEmpty;

    return Scaffold(
      appBar: selecting
          ? AppBar(
              leading: IconButton(
                tooltip: 'Cancel selection',
                onPressed: () => setState(_selected.clear),
                icon: const Icon(Icons.close),
              ),
              title: Text('${_selected.length} selected'),
              actions: [
                IconButton(
                  tooltip: 'Select all',
                  onPressed: _selected.length == flatPhotos.length
                      ? null
                      : () => _selectAll(flatPhotos),
                  icon: const Icon(Icons.select_all),
                ),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: () => _deleteSelected(flatPhotos),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            )
          : AppBar(
              title: const Text('Sony Transfer'),
              actions: [
                IconButton(
                  tooltip: 'Connect camera',
                  onPressed: widget.onOpenTransfer,
                  icon: const Icon(Icons.photo_camera_outlined),
                ),
              ],
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: switch ((_loading, _error, _sections.isEmpty)) {
          (true, _, _) =>
            const Center(child: CircularProgressIndicator()),
          (false, final error?, _) => _ErrorState(message: error, onRetry: _load),
          (false, null, true) => _EmptyAlbum(onConnect: widget.onOpenTransfer),
          _ => CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  sliver: SliverToBoxAdapter(
                    child: Text(
                      '$_totalPhotos transferred',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).hintColor,
                          ),
                    ),
                  ),
                ),
                for (final section in _sections) ...[
                  SliverToBoxAdapter(child: _DayHeader(section: section)),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 4,
                        crossAxisSpacing: 4,
                      ),
                      itemCount: section.photos.length,
                      itemBuilder: (context, index) {
                        final photo = section.photos[index];
                        return _PhotoTile(
                          key: ValueKey(photo.id),
                          photo: photo,
                          selecting: selecting,
                          selected: _selected.contains(photo.id),
                          onTap: selecting
                              ? () => _toggle(photo)
                              : () => _openPreview(flatPhotos, photo),
                          onLongPress: () => _toggle(photo),
                        );
                      },
                    ),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ],
            ),
        },
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.section});

  final TransferredDaySection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(_dayLabel(section.day), style: theme.textTheme.titleSmall),
          ),
          Text(
            '${section.photos.length}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }

  static String _dayLabel(DateTime day) {
    final today = DateTime.now();
    final startOfToday = DateTime(today.year, today.month, today.day);
    final difference = startOfToday.difference(day).inDays;
    if (difference == 0) return 'Today';
    if (difference == 1) return 'Yesterday';
    final month = day.month.toString().padLeft(2, '0');
    final dayOfMonth = day.day.toString().padLeft(2, '0');
    return '${day.year}-$month-$dayOfMonth';
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    super.key,
    required this.photo,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final TransferredPhoto photo;

  /// Whether the album is in selection mode — every tile then shows its
  /// check marker, not just the selected ones, so the mode is visible.
  final bool selecting;

  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Image.file(
              photo.file,
              fit: BoxFit.cover,
              // Decoded at roughly tile resolution rather than full size, so a
              // grid of dozens of already-downloaded, full-resolution JPEGs does
              // not each cost the memory of a full decode just to show a thumbnail.
              cacheWidth: 240,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined),
            ),
          ),
          if (selected)
            DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.25),
                border: Border.all(color: theme.colorScheme.primary, width: 2),
              ),
            ),
          if (selecting)
            Positioned(
              top: 4,
              right: 4,
              child: Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 20,
                color: selected ? theme.colorScheme.primary : Colors.white70,
                shadows: const [Shadow(blurRadius: 4, color: Colors.black54)],
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyAlbum extends StatelessWidget {
  const _EmptyAlbum({required this.onConnect});

  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
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
                    'Connect the camera and transfer some shots — they will '
                    'show up here.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.hintColor),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: onConnect,
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Connect camera'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
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
                  Text('Could not load the album', textAlign: TextAlign.center),
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
          ),
        ),
      ),
    );
  }
}
