import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Last camera Wi-Fi credentials the user successfully used.
///
/// Kept as a plain file under the app documents directory (not SharedPreferences)
/// so we do not pull in an Android plugin that fails Kotlin incremental compile
/// when the pub-cache and project live on different Windows drive letters.
class SavedWifiCredentials {
  const SavedWifiCredentials({
    this.ssid,
    this.password,
    this.autoConnect = true,
  });

  final String? ssid;
  final String? password;

  /// Whether a sighting of [ssid] should join automatically instead of
  /// waiting for the user to tap Connect.
  final bool autoConnect;

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'camera_wifi.json'));
  }

  static Future<SavedWifiCredentials> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const SavedWifiCredentials();
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return SavedWifiCredentials(
        ssid: json['ssid'] as String?,
        password: json['password'] as String?,
        autoConnect: json['autoConnect'] as bool? ?? true,
      );
    } catch (_) {
      return const SavedWifiCredentials();
    }
  }

  /// Updates the remembered network, keeping whatever [autoConnect] was set
  /// to previously.
  static Future<void> save({
    required String ssid,
    required String password,
  }) async {
    final current = await load();
    await _write(
      SavedWifiCredentials(
        ssid: ssid,
        password: password,
        autoConnect: current.autoConnect,
      ),
    );
  }

  static Future<void> saveAutoConnect(bool value) async {
    final current = await load();
    await _write(
      SavedWifiCredentials(
        ssid: current.ssid,
        password: current.password,
        autoConnect: value,
      ),
    );
  }

  static Future<void> _write(SavedWifiCredentials creds) async {
    final file = await _file();
    await file.writeAsString(
      jsonEncode({
        'ssid': creds.ssid,
        'password': creds.password,
        'autoConnect': creds.autoConnect,
      }),
    );
  }
}
