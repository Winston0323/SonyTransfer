import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

/// One downloadable rendition of a shot, as advertised in the camera's DIDL-Lite
/// `<res>` element.
class CameraResource {
  const CameraResource({
    required this.url,
    this.byteSize,
    this.resolution,
    this.protocolInfo = '',
  });

  final String url;

  /// Only the full-quality JPEG carries a byte count. Resized renditions and
  /// thumbnails leave it out.
  final int? byteSize;

  /// Pixel dimensions as `WIDTHxHEIGHT`, when the camera reports them.
  final String? resolution;

  final String protocolInfo;

  bool get isOriginal => byteSize != null;

  bool get isThumbnail => protocolInfo.contains('_TN');
}

/// A single shot on the card, with every rendition the camera is willing to serve.
class CameraItem {
  CameraItem({
    required this.id,
    required this.title,
    required this.resources,
    required this.folder,
    this.captured,
  });

  final String id;
  final String title;
  final String folder;
  final List<CameraResource> resources;

  /// Capture time from the DIDL `dc:date`, when the camera reports one.
  final DateTime? captured;

  /// The largest rendition that the camera reports a byte count for.
  ///
  /// Absence of any such rendition is how a raw-only shot gives itself away: for
  /// ARW files the camera exposes just the embedded preview JPEGs, never the raw
  /// data itself.
  CameraResource? get original {
    CameraResource? best;
    for (final res in resources) {
      if (res.byteSize == null) continue;
      if (best == null || res.byteSize! > best.byteSize!) best = res;
    }
    return best;
  }

  bool get isRawOnly =>
      original == null || p.extension(title).toUpperCase() == '.ARW';

  CameraResource? _byTag(String tag) =>
      resources.where((r) => r.protocolInfo.contains(tag)).firstOrNull;

  /// Rendition for a grid tile: big enough not to look mushy, small enough that
  /// a screenful loads quickly over the camera's 2.4GHz link.
  CameraResource? get thumbnail =>
      _byTag('_SM') ?? _byTag('_TN') ?? resources.firstOrNull;

  /// Larger rendition for the tap-and-hold preview.
  CameraResource? get preview => _byTag('_LRG') ?? thumbnail;

  /// `dc:title` usually already carries the extension; fall back to the one in
  /// the download URL when it does not.
  String get fileName {
    if (p.extension(title).isNotEmpty) return title;
    final res = original ?? (resources.isEmpty ? null : resources.last);
    final fromUrl =
        res == null ? '' : p.extension(Uri.parse(res.url).path.split('/').last);
    return '$title${fromUrl.isEmpty ? '.JPG' : fromUrl}';
  }

  int get byteSize => original?.byteSize ?? 0;
}
