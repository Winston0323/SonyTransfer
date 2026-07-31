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
  const SavedWifiCredentials({this.ssid, this.password});

  final String? ssid;
  final String? password;

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
      );
    } catch (_) {
      return const SavedWifiCredentials();
    }
  }

  static Future<void> save({
    required String ssid,
    required String password,
  }) async {
    final file = await _file();
    await file.writeAsString(
      jsonEncode({'ssid': ssid, 'password': password}),
    );
  }
}
