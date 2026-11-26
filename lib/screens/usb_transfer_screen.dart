import 'dart:async';

import 'package:flutter/material.dart';

import '../models/camera_item.dart';
import '../models/timeline.dart';
import '../models/usb_card.dart';
import '../services/destination_folder.dart';
import '../services/transfer_service.dart';
import '../services/usb_camera.dart';
import '../widgets/timeline_view.dart';
import '../widgets/transfer_bottom_bar.dart';

enum _Stage { idle, connecting, connected, transferring, finished }

final ButtonStyle _compactButtonStyle = TextButton.styleFrom(
  minimumSize: Size.zero,
  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
);

/// Cable transfer flow, laid out like [TransferScreen]: status panel on top,
/// shared [TimelineView] for the shot grid, shared transfer bottom bar.
///
/// The camera should be in Mass Storage + USB LUN Multi so each SD card is a
/// volume; when the phone forces MTP, Slot 1 is still reachable.
class UsbTransferScreen extends StatefulWidget {
  const UsbTransferScreen({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  State<UsbTransferScreen> createState() => _UsbTransferScreenState();
}

class _UsbTransferScreenState extends State<UsbTransferScreen> {
  final TransferService _transfer = TransferService();
  final ValueNotifier<TransferProgress?> _progress = ValueNotifier(null);
  final ScrollController _scrollController = ScrollController();

  _Stage _stage = _Stage.idle;
  List<UsbCard> _cards = const [];
  int? _cardId;
  List<CameraItem> _items = const [];
  List<TimelineSection> _sections = const [];
  final Set<String> _selected = {};
  final Map<String, TransferOutcome> _outcomes = {};

  bool _loading = false;
  int _done = 0;
  int _queueLength = 0;
  String? _error;
  String _status = '';
  String? _hint;
  String? _destinationFolderName;

  @override
  void initState() {
    super.initState();
    _loadDestinationFolder();
    _connect();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _progress.dispose();
    _transfer.close();
    unawaited(UsbCamera.close());
    super.dispose();
  }

  int get _transferable => _items.where((i) => !i.isRawOnly).length;

  Iterable<CameraItem> get _transferableItems =>
      _items.where((i) => !i.isRawOnly);

  Future<void> _loadDestinationFolder() async {
    final name = await DestinationFolder.currentName();
    if (!mounted) return;
    setState(() => _destinationFolderName = name);
  }

  Future<void> _pickDestinationFolder() async {
    final result = await DestinationFolder.pick();
    if (!mounted) return;
    final name = await DestinationFolder.currentName() ?? result.name;
    if (!mounted) return;
    setState(() => _destinationFolderName = name);
  }

  Future<void> _clearDestinationFolder() async {
    await DestinationFolder.clear();
    if (!mounted) return;
    setState(() => _destinationFolderName = null);
  }

  Future<void> _connect() async {
    setState(() {
      _stage = _Stage.connecting;
      _loading = true;
      _error = null;
      _items = const [];
      _sections = const [];
      _cards = const [];
      _cardId = null;
      _selected.clear();
      _outcomes.clear();
      _status = 'Looking for the camera…';
      _hint = null;
    });

    var status = await UsbCamera.status();
    if (!status.attached) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.idle;
        _loading = false;
        _error =
            'No camera over USB. On the camera: Ctrl w/ Smartphone → Off, '
            'USB Connection → Mass Storage, USB LUN Setting → Multi, then '
            'plug in the cable.';
        _status = '';
      });
      return;
    }

    if (!status.hasPermission) {
      setState(() => _status = 'Allow USB access…');
      status = await UsbCamera.requestPermission();
      if (!status.hasPermission) {
        if (!mounted) return;
        setState(() {
          _stage = _Stage.idle;
          _loading = false;
          _error =
              'USB permission denied. Unplug and plug back in, then Allow.';
          _status = '';
        });
        return;
      }
    }

    setState(() => _status = 'Allow photo access…');
    await UsbCamera.requestMediaPermission();
    await _loadCards();
  }

  Future<void> _loadCards() async {
    setState(() {
      _loading = true;
      _error = null;
      _status = 'Reading memory cards…';
    });
    try {
      final result = await UsbCamera.listCards();
      if (!mounted) return;
      if (result.cards.isEmpty) {
        setState(() {
          _stage = _Stage.idle;
          _loading = false;
          _cards = const [];
          _error = result.detail ??
              'Camera found, but no photo cards. Set USB Connection to '
                  'Mass Storage, USB LUN Setting to Multi, then unplug and '
                  'plug back in. Wait a few seconds for exFAT cards to mount.';
          _status = '';
        });
        return;
      }

      final preferredId =
          suggestedUsbCardId(result.cards) ?? result.cards.first.id;
      setState(() {
        _stage = _Stage.connected;
        _cards = result.cards;
        _cardId = preferredId;
        _hint = result.detail;
      });
      await _loadJpegs(preferredId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.idle;
        _loading = false;
        _error = '$e';
        _status = '';
      });
    }
  }

  Future<void> _loadJpegs(int cardId) async {
    setState(() {
      _loading = true;
      _error = null;
      _status = 'Listing JPEGs…';
      _selected.clear();
      _outcomes.clear();
    });
    try {
      final items = await UsbCamera.listJpegs(cardId);
      if (!mounted) return;
      setState(() {
        _cardId = cardId;
        _items = items;
        _sections = groupIntoTimeline(items);
        _loading = false;
        _status = items.isEmpty
            ? 'Camera connected, but this card has no JPEGs.'
            : 'Tap shots to choose what to transfer.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

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

  Future<void> _downloadSelected() async {
    final queue =
        _transferableItems.where((i) => _selected.contains(i.id)).toList();
    if (queue.isEmpty) return;

    _transfer.resetCancel();
    setState(() {
      _stage = _Stage.transferring;
      _done = 0;
      _queueLength = queue.length;
      _error = null;
      _status = 'Transferring…';
    });

    await for (final result in _transfer.transferAll(
      queue,
      onProgress: (progress) => _progress.value = progress,
    )) {
      if (!mounted) return;
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
    if (!mounted) return;

    final cancelled = _transfer.isCancelled;
    final saved =
        _outcomes.values.where((o) => o == TransferOutcome.saved).length;
    final failed =
        _outcomes.values.where((o) => o == TransferOutcome.failed).length;
    final rate = '${formatBytes(_transfer.averageBytesPerSecond.round())}/s';
    _progress.value = null;
    setState(() {
      _stage = _Stage.finished;
      if (!cancelled) _selected.clear();
      _status = cancelled
          ? 'Cancelled after $saved saved, averaging $rate.'
          : 'Saved $saved of ${queue.length}'
              '${failed > 0 ? ', $failed failed' : ''}, averaging $rate.';
    });
  }

  Future<void> _disconnect() async {
    await UsbCamera.close();
    if (!mounted) return;
    setState(() {
      _stage = _Stage.idle;
      _loading = false;
      _items = const [];
      _sections = const [];
      _cards = const [];
      _cardId = null;
      _selected.clear();
      _outcomes.clear();
      _error = null;
      _hint = null;
      _status = 'Disconnected from USB.';
      _done = 0;
      _queueLength = 0;
    });
    _progress.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final connected =
        _stage == _Stage.connected ||
        _stage == _Stage.transferring ||
        _stage == _Stage.finished;
    final transferring = _stage == _Stage.transferring;

    return Scaffold(
      appBar: AppBar(
        leading: widget.onBack == null
            ? null
            : BackButton(onPressed: widget.onBack),
        title: const Text('Sony Transfer'),
        actions: [
          if (connected && !transferring)
            IconButton(
              tooltip: 'Refresh',
              onPressed: _connect,
              icon: const Icon(Icons.refresh),
            ),
          if (_sections.isNotEmpty && !transferring) ...[
            IconButton(
              tooltip: 'Select all',
              onPressed:
                  _selected.length == _transferable ? null : _selectAll,
              icon: const Icon(Icons.select_all),
            ),
            IconButton(
              tooltip: 'Select none',
              onPressed: _selected.isEmpty ? null : _clearSelection,
              icon: const Icon(Icons.deselect),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              controller: _scrollController,
              primary: false,
              slivers: [
                SliverToBoxAdapter(
                  child: _StatusPanel(
                    stage: _stage,
                    cards: _cards,
                    cardId: _cardId,
                    busy: transferring || _stage == _Stage.connecting,
                    onSelectCard: _loadJpegs,
                    status: _status,
                    error: _error,
                    hint: _hint,
                    destinationFolderName: _destinationFolderName,
                    onPickDestinationFolder: _pickDestinationFolder,
                    onClearDestinationFolder: _clearDestinationFolder,
                    itemCount: _items.length,
                    transferable: _transferable,
                    selectedCount: _selected.length,
                    onConnect: _connect,
                    onDisconnect: connected ? _disconnect : null,
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
            visible: connected,
            transferring: transferring,
            selectedCount: _selected.length,
            queueLength: _queueLength,
            done: _done,
            progress: _progress,
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
    required this.cards,
    required this.cardId,
    required this.busy,
    required this.onSelectCard,
    required this.status,
    required this.error,
    required this.hint,
    required this.destinationFolderName,
    required this.onPickDestinationFolder,
    required this.onClearDestinationFolder,
    required this.itemCount,
    required this.transferable,
    required this.selectedCount,
    required this.onConnect,
    required this.onDisconnect,
  });

  final _Stage stage;
  final List<UsbCard> cards;
  final int? cardId;
  final bool busy;
  final ValueChanged<int> onSelectCard;
  final String status;
  final String? error;
  final String? hint;
  final String? destinationFolderName;
  final VoidCallback onPickDestinationFolder;
  final VoidCallback onClearDestinationFolder;
  final int itemCount;
  final int transferable;
  final int selectedCount;
  final VoidCallback onConnect;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connecting = stage == _Stage.connecting;
    final connected = stage != _Stage.idle && stage != _Stage.connecting;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                connected ? Icons.usb : Icons.usb_outlined,
                color: connected
                    ? theme.colorScheme.primary
                    : theme.disabledColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  connected ? 'USB camera' : 'Not connected',
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!connected)
                FilledButton.icon(
                  onPressed: busy ? null : onConnect,
                  icon: connecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.usb),
                  label: Text(connecting ? 'Connecting' : 'Connect'),
                )
              else if (onDisconnect != null)
                TextButton(
                  onPressed: busy ? null : onDisconnect,
                  style: _compactButtonStyle,
                  child: const Text('Disconnect'),
                ),
            ],
          ),
          if (connected) ...[
            const SizedBox(height: 4),
            Text(
              'Cable transfer · Mass Storage or MTP',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
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
            if (cards.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Memory card',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.hintColor),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final card in cards)
                    ChoiceChip(
                      label: Text(
                        '${card.label}  (${card.jpegCount} JPG'
                        '${card.rawCount > 0 ? ', ${card.rawCount} RAW' : ''})',
                      ),
                      selected: cardId == card.id,
                      onSelected: busy ? null : (_) => onSelectCard(card.id),
                    ),
                ],
              ),
            ],
            if (hint != null && hint!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                hint!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor),
              ),
            ],
            if (itemCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                '$itemCount shots · $transferable as JPEG · $selectedCount selected',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                'Tap a shot to see it big · corner box selects',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor),
              ),
            ],
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

class _Instructions extends StatelessWidget {
  const _Instructions();

  static const List<String> _steps = [
    'On the camera: MENU → Network → Ctrl w/ Smartphone → Off.',
    'MENU → Setup → USB Connection → Mass Storage.',
    'MENU → Setup → USB LUN Setting → Multi (both cards). MTP only sees Slot 1.',
    'Plug in a data-capable cable, Allow USB access, and tap Connect.',
    'Pick the JPEG memory card chip if both volumes appear, then select shots.',
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
            'If the phone keeps the camera in MTP, Slot 1 still works. For the '
            'JPEG card in Slot 2, Mass Storage + Multi is required.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}
