import 'dart:io';

import 'package:flutter/material.dart';

import '../services/thumbnail_cache.dart';

/// A camera-served image backed by [ThumbnailCache].
///
/// Behaves like `Image.network(url)` from the outside, but a shot already
/// seen once loads instantly from disk instead of asking the camera again,
/// and bursts of new requests (fast scrolling) are throttled so they do not
/// bottleneck each other on the camera's slow embedded server.
class CachedCameraImage extends StatefulWidget {
  const CachedCameraImage({
    super.key,
    required this.url,
    required this.fit,
    this.loadingBuilder,
    this.errorBuilder,
  });

  final String url;
  final BoxFit fit;
  final WidgetBuilder? loadingBuilder;
  final WidgetBuilder? errorBuilder;

  @override
  State<CachedCameraImage> createState() => _CachedCameraImageState();
}

class _CachedCameraImageState extends State<CachedCameraImage> {
  late Future<File> _future = ThumbnailCache.instance.fileFor(widget.url);

  @override
  void didUpdateWidget(covariant CachedCameraImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _future = ThumbnailCache.instance.fileFor(widget.url);
    }
  }

  Widget _fallback(BuildContext context, WidgetBuilder? builder) =>
      builder?.call(context) ?? const Icon(Icons.broken_image_outlined);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _fallback(context, widget.errorBuilder);
        }
        final file = snapshot.data;
        if (file == null) {
          return widget.loadingBuilder?.call(context) ??
              const SizedBox.shrink();
        }
        return Image.file(
          file,
          fit: widget.fit,
          gaplessPlayback: true,
          errorBuilder: (context, _, _) =>
              _fallback(context, widget.errorBuilder),
        );
      },
    );
  }
}
