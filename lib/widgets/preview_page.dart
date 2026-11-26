import 'package:flutter/material.dart';

import '../models/camera_item.dart';
import 'cached_camera_image.dart';

/// Full-screen photo viewer. Swiping moves through every shot in the
/// timeline, in the same order the grid shows them, so swipe direction always
/// matches what a tap on the neighbouring tile would have opened.
class PreviewPage extends StatefulWidget {
  const PreviewPage({
    super.key,
    required this.items,
    required this.initialIndex,
    required this.selected,
    required this.onToggle,
  });

  final List<CameraItem> items;
  final int initialIndex;

  /// Selection at the moment the page opened. Kept as a local copy so each
  /// swipe reflects it immediately rather than waiting on the caller to
  /// rebuild this page.
  final Set<String> selected;

  final ValueChanged<CameraItem> onToggle;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  late final Set<String> _selected = Set.of(widget.selected);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle(CameraItem item) {
    widget.onToggle(item);
    setState(() {
      if (!_selected.remove(item.id)) _selected.add(item.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.items[_index];
    final isSelected = _selected.contains(item.id);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          '${_index + 1} / ${widget.items.length}',
          style: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
        ),
        actions: [
          if (!item.isRawOnly)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: () => _toggle(item),
                icon: Icon(
                  isSelected ? Icons.check_circle : Icons.circle_outlined,
                  color: isSelected ? theme.colorScheme.primary : Colors.white,
                ),
                label: Text(
                  isSelected ? 'Selected' : 'Select',
                  style: TextStyle(
                    color:
                        isSelected ? theme.colorScheme.primary : Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.items.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) {
          final url = widget.items[index].preview?.url;
          return InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: Center(
              child: url == null
                  ? const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 48,
                    )
                  : CachedCameraImage(
                      url: url,
                      fit: BoxFit.contain,
                      // USB grid tiles use device thumbs; preview needs the
                      // full JPEG so swipe-browse matches Wi-Fi quality.
                      fullQuality: url.startsWith('usb:'),
                      errorBuilder: (_) => const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white54,
                        size: 48,
                      ),
                      loadingBuilder: (_) => const CircularProgressIndicator(
                        color: Colors.white54,
                      ),
                    ),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Text(
            item.isRawOnly
                ? '${item.fileName} · raw, preview only'
                : item.fileName,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
          ),
        ),
      ),
    );
  }
}
