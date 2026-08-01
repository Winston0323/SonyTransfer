import 'package:flutter/material.dart';

import '../models/camera_item.dart';
import '../models/timeline.dart';
import '../services/transfer_service.dart';
import 'cached_camera_image.dart';
import 'preview_page.dart';

/// Shots grouped by capture day, newest first, with tap-to-select tiles.
class TimelineView extends StatelessWidget {
  const TimelineView({
    super.key,
    required this.sections,
    required this.selected,
    required this.outcomes,
    required this.onToggle,
    required this.onToggleDay,
    this.loadingMore = false,
  });

  final List<TimelineSection> sections;
  final Set<String> selected;
  final Map<String, TransferOutcome> outcomes;

  /// Older shots are still on their way, so the end of the list is not the end
  /// of the card.
  final bool loadingMore;
  final ValueChanged<CameraItem> onToggle;
  final ValueChanged<TimelineSection> onToggleDay;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: slivers(
        sections: sections,
        selected: selected,
        outcomes: outcomes,
        onToggle: onToggle,
        onToggleDay: onToggleDay,
        loadingMore: loadingMore,
      ),
    );
  }

  /// The day headers, grids, and trailing footer as bare slivers, so a parent
  /// screen can drop them straight into its own [CustomScrollView] instead of
  /// nesting a second, independently-scrolling one below the setup panel.
  static List<Widget> slivers({
    required List<TimelineSection> sections,
    required Set<String> selected,
    required Map<String, TransferOutcome> outcomes,
    required ValueChanged<CameraItem> onToggle,
    required ValueChanged<TimelineSection> onToggleDay,
    bool loadingMore = false,
  }) {
    // Flattened in display order, so swiping through the full-screen preview
    // steps through shots in exactly the order the grid shows them — day
    // sections in sequence, each section's own order within it.
    final flatItems = [for (final section in sections) ...section.items];
    final indexById = {
      for (var i = 0; i < flatItems.length; i++) flatItems[i].id: i,
    };

    return [
      for (final section in sections) ...[
        SliverToBoxAdapter(
          child: _DayHeader(
            section: section,
            selected: selected,
            onToggleDay: onToggleDay,
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ),
            itemCount: section.items.length,
            itemBuilder: (context, index) {
              final item = section.items[index];
              return _ShotTile(
                key: ValueKey(item.id),
                item: item,
                selected: selected.contains(item.id),
                outcome: outcomes[item.id],
                onToggle: () => onToggle(item),
                onOpenPreview: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => PreviewPage(
                      items: flatItems,
                      initialIndex: indexById[item.id]!,
                      selected: selected,
                      onToggle: onToggle,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
      SliverToBoxAdapter(
        child:
            loadingMore ? const _LoadingOlder() : const SizedBox(height: 12),
      ),
    ];
  }
}

class _LoadingOlder extends StatelessWidget {
  const _LoadingOlder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            'Loading older shots',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.section,
    required this.selected,
    required this.onToggleDay,
  });

  final TimelineSection section;
  final Set<String> selected;
  final ValueChanged<TimelineSection> onToggleDay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transferable =
        section.items.where((i) => !i.isRawOnly).map((i) => i.id).toSet();
    final allChosen =
        transferable.isNotEmpty && selected.containsAll(transferable);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              timelineDayLabel(section.day),
              style: theme.textTheme.titleSmall,
            ),
          ),
          Text(
            '${section.items.length}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          if (transferable.isNotEmpty)
            TextButton(
              onPressed: () => onToggleDay(section),
              child: Text(allChosen ? 'None' : 'All'),
            ),
        ],
      ),
    );
  }
}

class _ShotTile extends StatelessWidget {
  const _ShotTile({
    super.key,
    required this.item,
    required this.selected,
    required this.outcome,
    required this.onToggle,
    required this.onOpenPreview,
  });

  final CameraItem item;
  final bool selected;
  final TransferOutcome? outcome;
  final VoidCallback onToggle;
  final VoidCallback onOpenPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = item.thumbnail?.url;

    return GestureDetector(
      onTap: onOpenPreview,
      // Long-press picks shots without aiming for the corner box, the way a
      // gallery app does.
      onLongPress: item.isRawOnly ? null : onToggle,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: theme.colorScheme.surfaceContainerHighest,
            child: url == null
                ? const Icon(Icons.broken_image_outlined)
                : CachedCameraImage(
                    url: url,
                    fit: BoxFit.cover,
                    errorBuilder: (_) =>
                        const Icon(Icons.broken_image_outlined),
                    loadingBuilder: (_) => const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
          ),
          if (item.isRawOnly)
            Container(
              color: Colors.black54,
              alignment: Alignment.center,
              child: Text(
                'RAW',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: Colors.white70),
              ),
            ),
          if (selected)
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.primary, width: 3),
                color: theme.colorScheme.primary.withValues(alpha: 0.25),
              ),
            ),
          if (!item.isRawOnly)
            Positioned(
              top: 0,
              right: 0,
              child: _SelectBox(selected: selected, onTap: onToggle),
            ),
          if (outcome != null)
            Positioned(
              bottom: 4,
              right: 4,
              child: _OutcomeDot(outcome: outcome!),
            ),
        ],
      ),
    );
  }
}

/// The tap target that picks a shot, kept distinct from the tile so tapping the
/// picture itself can open the preview.
class _SelectBox extends StatelessWidget {
  const _SelectBox({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      // Transparent rather than null, so the padding around the icon still takes
      // the tap instead of letting it fall through to the preview.
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? Colors.white : Colors.black38,
          ),
          child: Icon(
            selected ? Icons.check_circle : Icons.circle_outlined,
            size: 24,
            color: selected ? theme.colorScheme.primary : Colors.white,
          ),
        ),
      ),
    );
  }
}

class _OutcomeDot extends StatelessWidget {
  const _OutcomeDot({required this.outcome});

  final TransferOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color) = switch (outcome) {
      TransferOutcome.saved => (Icons.check_circle, Colors.green),
      TransferOutcome.skippedExisting => (Icons.done_all, Colors.white70),
      TransferOutcome.skippedRaw => (Icons.remove_circle_outline, Colors.white38),
      TransferOutcome.failed => (
          Icons.error,
          Theme.of(context).colorScheme.error
        ),
    };

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.black54,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 18, color: color),
    );
  }
}
