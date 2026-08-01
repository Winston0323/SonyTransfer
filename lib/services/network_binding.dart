import 'package:flutter/services.dart';

/// Why a Wi-Fi scan came back without any camera network.
enum WifiScanProblem {
  wifiOff,
  permissionDenied,

  /// Android returns no scan results while the device location toggle is off,
  /// even when the permission itself is granted.
  locationOff,

  /// Android allows only a handful of scans per couple of minutes.
  throttled,

  /// The scan worked; nothing camera-like was in range.
  noneFound,

  /// Not Android.
  unsupported,
}

/// Result of one Wi-Fi scan.
class CameraWifiScan {
  const CameraWifiScan({
    this.cameras = const [],
    this.all = const [],
    this.problem,
  });

  /// Networks that look like a Sony access point.
  final List<String> cameras;

  /// Everything in range, so the user can still pick a camera whose name we
  /// did not recognise.
  final List<String> all;

  final WifiScanProblem? problem;
}

/// Outcome of [NetworkBinding.joinCameraWifi], carrying Android's own reason so a
/// refusal can be told apart from a dismissed prompt or a wrong password.
class WifiJoinResult {
  const WifiJoinResult({required this.ok, this.code, this.message});

  final bool ok;
  final String? code;
  final String? message;
}

/// Snapshot of the active Wi-Fi link's radio characteristics.
class WifiLinkInfo {
  const WifiLinkInfo({this.linkSpeedMbps, this.rssiDbm, this.frequencyMhz});

  final int? linkSpeedMbps;

  /// Signal strength. Roughly: -50 excellent, -67 good, -75 weak, -80 barely
  /// usable.
  final int? rssiDbm;

  final int? frequencyMhz;

  /// 2.4GHz is where every Sony "Send to Smartphone" access point broadcasts,
  /// so seeing anything else here would be the surprise worth a comment.
  bool get isTwoPointFourGhz =>
      frequencyMhz != null && frequencyMhz! < 3000;

  bool get isWeakSignal => rssiDbm != null && rssiDbm! <= -75;
}

/// How [NetworkBinding.disconnectWifi] left the camera network.
enum WifiDisconnectResult {
  /// This app owned the link and Android dropped it.
  released,

  /// The user had joined in Settings; the system Wi-Fi panel was opened.
  openedSettings,

  /// Nothing we tried worked.
  failed,
}

/// Pins this process's sockets to the Wi-Fi interface.
///
/// Without this the camera is unreachable on most phones: its access point has
/// no internet, so Android leaves the default route on mobile data.
class NetworkBinding {
  static const MethodChannel _channel = MethodChannel('sony_transfer/network');

  static Future<bool> bindToWifi() async {
    try {
      return await _channel.invokeMethod<bool>('bindToWifi') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Nearby networks, split into likely cameras and everything else.
  static Future<CameraWifiScan> scanCameraWifi() async {
    try {
      final raw =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('scanCameraWifi');
      if (raw == null) return const CameraWifiScan();
      return CameraWifiScan(
        cameras: (raw['cameras'] as List<dynamic>? ?? const []).cast<String>(),
        all: (raw['all'] as List<dynamic>? ?? const []).cast<String>(),
        problem: _problemFrom(raw['problem'] as String?),
      );
    } on MissingPluginException {
      return const CameraWifiScan(problem: WifiScanProblem.unsupported);
    }
  }

  static WifiScanProblem? _problemFrom(String? raw) => switch (raw) {
        'wifi_off' => WifiScanProblem.wifiOff,
        'permission_denied' => WifiScanProblem.permissionDenied,
        'location_off' => WifiScanProblem.locationOff,
        'throttled' => WifiScanProblem.throttled,
        'none_found' => WifiScanProblem.noneFound,
        _ => null,
      };

  /// Joins the camera AP as a temporary app-owned network.
  ///
  /// Android shows a required consent prompt, but does not save this network.
  static Future<WifiJoinResult> joinCameraWifi({
    String ssid = '',
    required String password,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'joinCameraWifi',
        {'ssid': ssid, 'password': password},
      );
      if (raw == null) {
        return const WifiJoinResult(
          ok: false,
          message: 'No response from Android.',
        );
      }
      return WifiJoinResult(
        ok: raw['ok'] == true,
        code: raw['code'] as String?,
        message: raw['message'] as String?,
      );
    } on PlatformException catch (e) {
      return WifiJoinResult(
        ok: false,
        code: e.code,
        message: e.message ?? 'Android rejected the Wi-Fi request.',
      );
    } on MissingPluginException {
      return const WifiJoinResult(
        ok: false,
        message: 'Joining Wi-Fi is only available on Android.',
      );
    }
  }

  static Future<void> openWifiSettings() async {
    try {
      await _channel.invokeMethod<bool>('openWifiSettings');
    } on PlatformException {
      // Nothing we can do from Dart.
    } on MissingPluginException {
      // Nothing we can do from Dart.
    }
  }

  static Future<void> openLocationSettings() async {
    try {
      await _channel.invokeMethod<bool>('openLocationSettings');
    } on PlatformException {
      // Nothing we can do from Dart.
    } on MissingPluginException {
      // Nothing we can do from Dart.
    }
  }

  static Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod<bool>('openAppSettings');
    } on PlatformException {
      // Nothing we can do from Dart.
    } on MissingPluginException {
      // Nothing we can do from Dart.
    }
  }

  /// SSID of the Wi-Fi the device is associated with, when readable.
  static Future<String?> currentWifiSsid() async {
    try {
      return await _channel.invokeMethod<String>('currentWifiSsid');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// The camera's likely address: the gateway of the Wi-Fi network we joined.
  ///
  /// Returns null off Android, or when no Wi-Fi network is attached.
  static Future<String?> wifiGateway() async {
    try {
      return await _channel.invokeMethod<String>('wifiGateway');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// PHY rate, signal strength, and band of the active Wi-Fi link, when
  /// Android is willing to report them (needs the same location access as
  /// [currentWifiSsid] on Android 8+).
  ///
  /// A link speed far below another device's is the app's best evidence of a
  /// radio/antenna gap rather than something the transfer code can fix; RSSI
  /// tells the difference between that and just standing too far from the
  /// camera.
  static Future<WifiLinkInfo> wifiLinkInfo() async {
    try {
      final raw =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('wifiLinkInfo');
      if (raw == null) return const WifiLinkInfo();
      return WifiLinkInfo(
        linkSpeedMbps: raw['linkSpeedMbps'] as int?,
        rssiDbm: raw['rssiDbm'] as int?,
        frequencyMhz: raw['frequencyMhz'] as int?,
      );
    } on PlatformException {
      return const WifiLinkInfo();
    } on MissingPluginException {
      return const WifiLinkInfo();
    }
  }

  static Future<void> unbind() async {
    try {
      await _channel.invokeMethod<bool>('unbind');
    } on PlatformException {
      // Nothing to release.
    } on MissingPluginException {
      // Nothing to release.
    }
  }

  /// Leaves the camera Wi-Fi. Prefer joining via [joinCameraWifi] so this can
  /// release an app-owned link; a Settings-joined network can only open the panel.
  static Future<WifiDisconnectResult> disconnectWifi() async {
    try {
      final raw = await _channel.invokeMethod<String>('disconnectWifi');
      return switch (raw) {
        'released' => WifiDisconnectResult.released,
        'opened_settings' => WifiDisconnectResult.openedSettings,
        _ => WifiDisconnectResult.failed,
      };
    } on PlatformException {
      return WifiDisconnectResult.failed;
    } on MissingPluginException {
      return WifiDisconnectResult.failed;
    }
  }
}
