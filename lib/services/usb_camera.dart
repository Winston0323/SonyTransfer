import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../models/camera_item.dart';
import '../models/usb_card.dart';

const MethodChannel _channel = MethodChannel('sony_transfer/network');
const EventChannel _events = EventChannel('sony_transfer/usb_events');

/// Cable-side access to a Sony body in Mass Storage + Multi LUN mode.
class UsbCamera {
  UsbCamera._();

  static Stream<String>? _eventStream;

  /// `attached` / `detached` as the camera is plugged or unplugged.
  static Stream<String> get events {
    return _eventStream ??= _events.receiveBroadcastStream().map((event) {
      if (event is Map && event['event'] is String) {
        return event['event'] as String;
      }
      return 'detached';
    });
  }

  static Future<UsbStatus> status() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('usbStatus');
      if (raw is! Map) return const UsbStatus();
      return UsbStatus(
        attached: raw['attached'] == true,
        hasPermission: raw['hasPermission'] == true,
        deviceCount: raw['deviceCount'] as int? ?? 0,
      );
    } on PlatformException {
      return const UsbStatus();
    } on MissingPluginException {
      return const UsbStatus();
    }
  }

  static Future<UsbStatus> requestPermission() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('usbRequestPermission');
      if (raw is! Map) return const UsbStatus();
      return UsbStatus(
        attached: raw['attached'] == true,
        hasPermission: raw['ok'] == true || raw['hasPermission'] == true,
        deviceCount: raw['deviceCount'] as int? ?? 0,
      );
    } on PlatformException {
      return const UsbStatus();
    } on MissingPluginException {
      return const UsbStatus();
    }
  }

  /// Needed for the MediaStore backend that sees exFAT cards the phone mounted.
  static Future<bool> requestMediaPermission() async {
    try {
      final raw =
          await _channel.invokeMethod<dynamic>('usbRequestMediaPermission');
      return raw is Map && raw['ok'] == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens every photo-looking volume and returns card summaries. Call again to
  /// refresh after the cable was replugged.
  static Future<UsbCardListResult> listCards() async {
    final raw = await _channel.invokeMethod<dynamic>('usbListCards');
    if (raw is List) {
      // Older payload shape — keep working during hot reload.
      return UsbCardListResult(
        cards: [
          for (final entry in raw)
            if (entry is Map) UsbCard.fromMap(entry),
        ],
      );
    }
    if (raw is! Map) return const UsbCardListResult();
    final list = raw['cards'];
    return UsbCardListResult(
      cards: [
        if (list is List)
          for (final entry in list)
            if (entry is Map) UsbCard.fromMap(entry),
      ],
      backend: raw['backend'] as String?,
      mode: raw['mode'] as String?,
      detail: raw['detail'] as String?,
    );
  }

  /// JPEG stills on [cardId], newest first.
  static Future<List<CameraItem>> listJpegs(int cardId) async {
    final raw = await _channel.invokeMethod<dynamic>(
      'usbListJpegs',
      {'cardId': cardId},
    );
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map) _itemFromMap(cardId, entry),
    ];
  }

  static Future<void> copyJpeg({
    required int cardId,
    required String usbPath,
    required String destPath,
  }) async {
    final raw = await _channel.invokeMethod<dynamic>(
      'usbCopyJpeg',
      {
        'cardId': cardId,
        'usbPath': usbPath,
        'destPath': destPath,
      },
    );
    if (raw is Map && raw['ok'] == true) return;
    final reason = raw is Map ? raw['reason']?.toString() : 'copy_failed';
    throw Exception(reason ?? 'copy_failed');
  }

  /// Small JPEG bytes for a grid tile (EXIF / MediaStore thumb).
  static Future<Uint8List?> loadThumb({
    required int cardId,
    required String usbPath,
    int maxEdge = 256,
  }) async {
    try {
      final raw = await _channel.invokeMethod<dynamic>(
        'usbLoadThumb',
        {
          'cardId': cardId,
          'usbPath': usbPath,
          'maxEdge': maxEdge,
        },
      );
      if (raw is Uint8List) return raw;
      if (raw is List<int>) return Uint8List.fromList(raw);
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> close() async {
    try {
      await _channel.invokeMethod<dynamic>('usbClose');
    } on PlatformException {
      // Already gone.
    } on MissingPluginException {
      // Tests / desktop.
    }
  }

  /// `usb://<cardId>/<url-encoded-path>` — path may be a FAT relative path or a
  /// `content://` MediaStore URI. [TransferService] recognises the scheme.
  static String urlFor(int cardId, String path) =>
      'usb://$cardId/${Uri.encodeComponent(path)}';

  static (int cardId, String path)? parseUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'usb') return null;
    final cardId = int.tryParse(uri.host);
    if (cardId == null) return null;
    if (uri.pathSegments.isEmpty) return null;
    // New form: a single encoded segment. Old form: plain path segments.
    if (uri.pathSegments.length == 1) {
      return (cardId, Uri.decodeComponent(uri.pathSegments.first));
    }
    final path = uri.pathSegments.map(Uri.decodeComponent).join('/');
    if (path.isEmpty) return null;
    return (cardId, path);
  }

  static CameraItem _itemFromMap(int cardId, Map<dynamic, dynamic> map) {
    final path = map['path'] as String? ?? '';
    final name = map['name'] as String? ?? path.split('/').last;
    final byteSize = (map['byteSize'] as num?)?.toInt();
    final modifiedMs = (map['modifiedMs'] as num?)?.toInt();
    final folder = map['folder'] as String? ?? 'DCIM';
    return CameraItem(
      id: 'usb:$cardId:$path',
      title: name,
      folder: folder,
      captured: modifiedMs == null || modifiedMs <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(modifiedMs),
      resources: [
        CameraResource(
          url: urlFor(cardId, path),
          byteSize: byteSize,
          protocolInfo: 'usb:image/jpeg',
        ),
      ],
    );
  }
}

class UsbStatus {
  const UsbStatus({
    this.attached = false,
    this.hasPermission = false,
    this.deviceCount = 0,
  });

  final bool attached;
  final bool hasPermission;
  final int deviceCount;
}

class UsbCardListResult {
  const UsbCardListResult({
    this.cards = const [],
    this.backend,
    this.mode,
    this.detail,
  });

  final List<UsbCard> cards;
  final String? backend;

  /// USB interface mode reported by the phone: `msc`, `mtp`, `both`, …
  final String? mode;

  /// Explains an empty result, or a caveat (e.g. MTP is Slot 1 only).
  final String? detail;
}
