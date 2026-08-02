import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('sony_transfer/network');

/// Outcome of asking the user to pick a destination folder.
class FolderPickResult {
  const FolderPickResult({required this.ok, this.name});

  final bool ok;

  /// The folder now in effect, whether or not this particular pick succeeded
  /// (a cancelled picker leaves an earlier choice, if any, untouched).
  final String? name;
}

/// Lets the user redirect downloaded shots to any folder reachable through
/// Android's document picker — an SD card, Downloads, a cloud-synced folder —
/// instead of the fixed Photos album this app saves to by default.
///
/// Backed by Android's Storage Access Framework rather than a raw filesystem
/// path, since that is the only way to reach an arbitrary folder under scoped
/// storage without a special all-files permission.
class DestinationFolder {
  const DestinationFolder._();

  static Future<FolderPickResult> pick() async {
    try {
      final raw =
          await _channel.invokeMethod<dynamic>('pickDestinationFolder');
      if (raw is! Map) return const FolderPickResult(ok: false);
      return FolderPickResult(
        ok: raw['ok'] == true,
        name: raw['name'] as String?,
      );
    } on PlatformException {
      return const FolderPickResult(ok: false);
    } on MissingPluginException {
      return const FolderPickResult(ok: false);
    }
  }

  /// The folder currently in effect, or null when saving to the Photos album.
  static Future<String?> currentName() async {
    try {
      return await _channel.invokeMethod<String>('currentDestinationName');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Reverts to the default Photos album.
  static Future<void> clear() async {
    try {
      await _channel.invokeMethod<bool>('clearDestinationFolder');
    } on PlatformException {
      // Nothing to release.
    } on MissingPluginException {
      // Nothing to release.
    }
  }

  /// Copies an already-downloaded file at [sourcePath] into the chosen
  /// folder as [fileName]. Only meaningful once [pick] has succeeded.
  static Future<DestinationSaveResult> save({
    required String sourcePath,
    required String fileName,
  }) async {
    try {
      // Untyped on purpose: the channel returns Map<Object?, Object?> whose
      // cast to Map<dynamic, dynamic> has thrown on some Flutter versions,
      // which used to make every destination save look like a failure and
      // dump the shot into the Photos album instead.
      final raw = await _channel.invokeMethod<dynamic>(
        'saveFileToDestination',
        {'sourcePath': sourcePath, 'fileName': fileName},
      );
      if (raw is Map && raw['ok'] == true) {
        return const DestinationSaveResult(ok: true);
      }
      final reason = raw is Map ? raw['reason']?.toString() : 'bad_reply';
      return DestinationSaveResult(ok: false, reason: reason);
    } on PlatformException catch (e) {
      return DestinationSaveResult(ok: false, reason: e.code);
    } on MissingPluginException {
      return const DestinationSaveResult(ok: false, reason: 'no_plugin');
    }
  }
}

/// Outcome of copying one shot into the user-chosen destination folder.
class DestinationSaveResult {
  const DestinationSaveResult({required this.ok, this.reason});

  final bool ok;
  final String? reason;
}
