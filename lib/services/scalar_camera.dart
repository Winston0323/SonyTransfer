import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// The camera refused or could not complete a remote-shooting call.
class ScalarException implements Exception {
  ScalarException(this.message, {this.code, this.retryable = false});

  final String message;
  final int? code;

  /// True when the same call is worth repeating: the camera was busy, the
  /// wait for the shutter timed out, or the socket was closed on purpose.
  final bool retryable;

  @override
  String toString() => message;
}

/// A camera that answered `getAvailableApiList` on its Scalar Web API.
class DiscoveredCamera {
  const DiscoveredCamera({
    required this.endpoint,
    required this.apis,
    this.name,
  });

  /// `http://host:port/sony/camera`
  final Uri endpoint;
  final List<String> apis;
  final String? name;
}

/// JSON-RPC client for Sony's camera remote API (Ctrl w/ Smartphone).
///
/// This is the API the A7 III generation exposes while the body is still in
/// shooting mode. It is a different service from Send to Smartphone, which
/// is the mode that takes over the camera until the copy finishes.
class ScalarCamera {
  ScalarCamera({
    required this.endpoint,
    http.Client? client,
    Duration timeout = const Duration(seconds: 8),
    bool ownsClient = true,
  })  : _timeout = timeout,
        _ownsClient = ownsClient,
        _client = client ?? http.Client();

  final Uri endpoint;
  final Duration _timeout;
  final bool _ownsClient;
  http.Client _client;
  int _id = 1;

  /// Drops whatever call is in flight (the long wait for the shutter) and
  /// opens a fresh client for the next one.
  void abortInFlight() {
    if (!_ownsClient) return;
    _client.close();
    _client = http.Client();
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<List<String>> availableApis() async {
    final apis = stringList(await _rpc('getAvailableApiList', const []));
    if (apis.isEmpty) {
      throw ScalarException('Camera returned an empty API list.');
    }
    return apis;
  }

  /// Asks the camera for the largest JPEG it will attach to a shutter event.
  ///
  /// `Original` is the full JPEG. Many bodies only offer `2M`. RAW is never
  /// part of this response — it stays on the card. A refusal of one size is
  /// not fatal: the next smaller size is tried, and live view still starts
  /// if every size is refused.
  Future<String?> preparePostview(List<String> apis) async {
    if (!apis.contains('setPostviewImageSize')) return null;
    var supported = const ['Original', '2M', 'VGA'];
    if (apis.contains('getSupportedPostviewImageSize')) {
      try {
        final reported =
            stringList(await _rpc('getSupportedPostviewImageSize', const []));
        if (reported.isNotEmpty) supported = reported;
      } on ScalarException {
        // Keep the usual three and let the set call say if it disagrees.
      }
    }
    final ordered = <String>[
      for (final size in const ['Original', '2M', 'VGA'])
        if (supported.contains(size)) size,
      for (final size in supported)
        if (size != 'Original' && size != '2M' && size != 'VGA') size,
    ];
    for (final choice in ordered) {
      try {
        await _rpc('setPostviewImageSize', [choice]);
        return choice;
      } on ScalarException {
        continue;
      }
    }
    return null;
  }

  Future<String> openLiveView(List<String> apis) async {
    try {
      return await _startLiveView(apis);
    } on ScalarException {
      if (!apis.contains('setShootMode')) rethrow;
      try {
        await _rpc('setShootMode', const ['still']);
      } on ScalarException {
        // The mode call can fail when the body is already in stills.
      }
      return _startLiveView(apis);
    }
  }

  Future<String> _startLiveView(List<String> apis) async {
    if (apis.contains('startLiveviewWithSize')) {
      try {
        return _liveViewUrl(await _rpc('startLiveviewWithSize', const ['L']));
      } on ScalarException {
        // Fall through to the unsized call.
      }
    }
    if (!apis.contains('startLiveview') &&
        !apis.contains('startLiveviewWithSize')) {
      throw ScalarException(
        'This connection has no live view. On the A7R III open '
        'MENU → Network → Ctrl w/ Smartphone → Connection, then try again.',
      );
    }
    return _liveViewUrl(await _rpc('startLiveview', const []));
  }

  Future<void> stopLiveView(List<String> apis) async {
    if (!apis.contains('stopLiveview')) return;
    try {
      await _rpc('stopLiveview', const []);
    } on ScalarException {
      // Already stopped, or the Wi-Fi is already gone.
    }
  }

  /// Blocks until the shutter on the camera is pressed, then returns the
  /// JPEG URL. An empty list means "try again" (timeout or camera busy).
  Future<List<String>> awaitNextPicture() async {
    try {
      final result = await _rpc(
        'awaitTakePicture',
        const [],
        timeout: const Duration(seconds: 90),
      );
      return pictureUrls(result);
    } on ScalarException catch (e) {
      if (e.retryable) return const [];
      rethrow;
    }
  }

  Future<List<String>> pollPictureEvents() async {
    final result = await _rpc(
      'getEvent',
      const [true],
      timeout: const Duration(seconds: 35),
    );
    return pictureUrlsInEvents(result);
  }

  Future<List<String>> takePicture() async {
    final result = await _rpc(
      'actTakePicture',
      const [],
      timeout: const Duration(seconds: 30),
    );
    return pictureUrls(result);
  }

  Future<dynamic> _rpc(
    String method,
    List<dynamic> params, {
    Duration? timeout,
  }) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            endpoint,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'method': method,
              'params': params,
              'id': _id++,
              'version': '1.0',
            }),
          )
          .timeout(timeout ?? _timeout);
    } on TimeoutException {
      throw ScalarException(
        'Timed out waiting for the camera.',
        retryable: true,
      );
    } catch (e) {
      if (e is ScalarException) rethrow;
      throw ScalarException('Camera request failed ($e).', retryable: true);
    }

    if (response.body.isEmpty) {
      throw ScalarException(
        'Camera returned HTTP ${response.statusCode} with an empty body.',
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw ScalarException(
        'Camera answered, but not with the remote-shooting API.',
      );
    }
    if (decoded is! Map) {
      throw ScalarException(
        'Camera answered, but not with the remote-shooting API.',
      );
    }
    final error = decoded['error'];
    if (error is List && error.isNotEmpty) {
      final code = error.first is int
          ? error.first as int
          : int.tryParse('${error.first}');
      final detail = error.length > 1 ? '${error[1]}'.trim() : '';
      throw ScalarException(
        detail.isEmpty ? 'Camera refused $method ($code).' : detail,
        code: code,
        retryable: code != null && _retryableCodes.contains(code),
      );
    }
    return decoded['result'];
  }

  static const Set<int> _retryableCodes = {1, 40400, 40401, 40403, 40405};
}

String _liveViewUrl(dynamic result) {
  if (result is List && result.isNotEmpty && result.first is String) {
    final url = result.first as String;
    if (url.startsWith('http')) return url;
  }
  throw ScalarException('Camera did not return a live view address.');
}

/// Sony wraps lists as either `["a"]` or `[["a"]]` depending on the method.
List<String> stringList(dynamic result) {
  if (result is! List || result.isEmpty) return const [];
  final first = result.first;
  if (first is List) return first.map((value) => '$value').toList();
  return result.map((value) => '$value').toList();
}

bool isShotUrl(String value) {
  final lower = value.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    return false;
  }
  if (lower.contains('liveview')) return false;
  return lower.contains('.jpg') || lower.contains('.jpeg');
}

/// URLs from `actTakePicture` / `awaitTakePicture`.
///
/// When the camera returns two, the last one is the larger original and the
/// first is the on-screen postview.
List<String> pictureUrls(dynamic result) {
  if (result is! List || result.isEmpty) return const [];
  final first = result.first;
  final raw = first is List ? first : result;
  return raw.whereType<String>().where(isShotUrl).toList();
}

String? pickShotUrl(List<String> urls) {
  final shots = urls.where(isShotUrl).toList();
  if (shots.isEmpty) return null;
  return shots.last;
}

/// JPEG URLs nested under a "picture" event. Ignores the live-view stream
/// address, which is also an HTTP URL in the same payload.
List<String> pictureUrlsInEvents(dynamic node) {
  final found = <String>[];
  void walk(dynamic value, {required bool inShot}) {
    if (value is Map) {
      final type = '${value['type'] ?? ''}'.toLowerCase();
      final shot = inShot ||
          type.contains('picture') ||
          type.contains('shutter');
      for (final child in value.values) {
        walk(child, inShot: shot);
      }
    } else if (value is List) {
      for (final child in value) {
        walk(child, inShot: inShot);
      }
    } else if (value is String && inShot && isShotUrl(value)) {
      found.add(value);
    }
  }

  walk(node, inShot: false);
  return found;
}

/// `http://host:port/sony/camera` from a Scalar device description.
Uri? cameraEndpointFromDescription(String body) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(body);
  } on XmlException {
    return null;
  }
  final services = doc.descendants.whereType<XmlElement>().where(
        (element) => element.name.local == 'X_ScalarWebAPI_Service',
      );
  for (final service in services) {
    String? type;
    String? url;
    for (final child in service.childElements) {
      if (child.name.local == 'X_ScalarWebAPI_ServiceType') {
        type = child.innerText.trim();
      } else if (child.name.local == 'X_ScalarWebAPI_ActionList_URL') {
        url = child.innerText.trim();
      }
    }
    if (url == null || url.isEmpty) continue;
    if (type != null && type.toLowerCase() != 'camera') continue;
    final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    return Uri.parse('$base/camera');
  }
  return null;
}

String? friendlyNameFromDescription(String body) {
  try {
    final doc = XmlDocument.parse(body);
    final name = doc.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'friendlyName')
        .map((element) => element.innerText.trim())
        .where((value) => value.isNotEmpty);
    return name.isEmpty ? null : name.first;
  } on XmlException {
    return null;
  }
}

const List<(int, String)> _descriptionPaths = [
  (61000, '/scalarwebapi_dd.xml'),
  (8080, '/dd.xml'),
  (64321, '/dd.xml'),
  (10000, '/dd.xml'),
  (80, '/description.xml'),
];

/// Finds the remote-shooting endpoint on the camera access point.
///
/// Tries the well-known ports first. SSDP is the fallback: Android often
/// drops the multicast unless a multicast lock is held by the caller.
Future<DiscoveredCamera> discoverScalarCamera({
  required List<String> hosts,
  http.Client? client,
  bool useSsdp = true,
  Future<String?> Function()? locateSsdp,
  Duration timeout = const Duration(milliseconds: 1200),
}) async {
  final http.Client httpClient = client ?? http.Client();
  final owns = client == null;
  try {
    final distinct = <String>[];
    for (final host in hosts) {
      final trimmed = host.trim();
      if (trimmed.isEmpty || distinct.contains(trimmed)) continue;
      distinct.add(trimmed);
    }
    if (distinct.isEmpty) {
      throw ScalarException('No camera address to try.');
    }

    // The camera drops Ctrl w/ Smartphone about a second after a station
    // associates unless something speaks its remote API. SSDP runs beside
    // the well-known port instead of after a chain of timeouts.
    final ssdpFuture = useSsdp
        ? _discoverViaSsdp(
            httpClient,
            timeout,
            locateSsdp ?? locateSonyDeviceDescription,
          )
        : Future<DiscoveredCamera?>.value(null);

    for (final host in distinct) {
      final found = await _probe(
        httpClient,
        Uri.parse('http://$host:8080/sony/camera'),
        timeout,
      );
      if (found != null) return found;
    }

    final viaSsdp = await ssdpFuture;
    if (viaSsdp != null) return viaSsdp;

    final rest = <Future<DiscoveredCamera?>>[
      for (final host in distinct) ...[
        _probe(
          httpClient,
          Uri.parse('http://$host:10000/sony/camera'),
          timeout,
        ),
        for (final path in _descriptionPaths)
          _probeDescription(
            httpClient,
            Uri.parse('http://$host:${path.$1}${path.$2}'),
            timeout,
          ),
      ],
    ];
    final found = await _firstDiscovered(rest);
    if (found != null) return found;

    throw ScalarException(
      'No remote-shooting service answered on ${distinct.join(', ')}.\n\n'
      'On the camera: MENU → Network → Ctrl w/ Smartphone → On, then open '
      'Connection and leave that screen up.\n\n'
      'Send to Smartphone is a different mode. It cannot show a live view, '
      'and it pauses shooting while it sends.',
    );
  } finally {
    if (owns) httpClient.close();
  }
}

Future<DiscoveredCamera?> _discoverViaSsdp(
  http.Client client,
  Duration timeout,
  Future<String?> Function() locate,
) async {
  try {
    final location = await locate();
    if (location == null || location.isEmpty) return null;
    return _probeDescription(client, Uri.parse(location), timeout);
  } catch (_) {
    return null;
  }
}

Future<DiscoveredCamera?> _firstDiscovered(
  List<Future<DiscoveredCamera?>> pending,
) {
  if (pending.isEmpty) return Future<DiscoveredCamera?>.value(null);
  final done = Completer<DiscoveredCamera?>();
  var left = pending.length;
  for (final future in pending) {
    future.then(
      (found) {
        if (found != null && !done.isCompleted) done.complete(found);
        left -= 1;
        if (left == 0 && !done.isCompleted) done.complete(null);
      },
      onError: (_) {
        left -= 1;
        if (left == 0 && !done.isCompleted) done.complete(null);
      },
    );
  }
  return done.future;
}

Future<DiscoveredCamera?> _probe(
  http.Client client,
  Uri endpoint,
  Duration timeout,
) async {
  try {
    final camera = ScalarCamera(
      endpoint: endpoint,
      client: client,
      timeout: timeout,
      ownsClient: false,
    );
    final apis = await camera.availableApis();
    return DiscoveredCamera(endpoint: endpoint, apis: apis);
  } catch (_) {
    return null;
  }
}

Future<DiscoveredCamera?> _probeDescription(
  http.Client client,
  Uri description,
  Duration timeout,
) async {
  try {
    final response = await client.get(description).timeout(timeout);
    if (response.statusCode != 200 || response.body.isEmpty) return null;
    final endpoint = cameraEndpointFromDescription(response.body);
    if (endpoint == null) return null;
    final found = await _probe(client, endpoint, timeout);
    if (found == null) return null;
    return DiscoveredCamera(
      endpoint: found.endpoint,
      apis: found.apis,
      name: friendlyNameFromDescription(response.body),
    );
  } catch (_) {
    return null;
  }
}

/// SSDP search for `ScalarWebAPI`. Returns the description URL, or null.
Future<String?> locateSonyDeviceDescription({
  Duration listenFor = const Duration(milliseconds: 1500),
}) async {
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    try {
      socket.joinMulticast(InternetAddress('239.255.255.250'));
    } catch (_) {
      // Some phones still deliver the unicast reply without the join.
    }
    void search(String target) {
      final payload = utf8.encode(
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 1\r\n'
        'ST: $target\r\n'
        '\r\n',
      );
      socket?.send(payload, InternetAddress('239.255.255.250'), 1900);
    }

    final completer = Completer<String?>();
    final bound = socket;
    late StreamSubscription<RawSocketEvent> subscription;
    subscription = bound.listen((event) {
      if (event != RawSocketEvent.read || completer.isCompleted) return;
      final datagram = bound.receive();
      if (datagram == null) return;
      final text = utf8.decode(datagram.data, allowMalformed: true);
      final location = RegExp(
        r'LOCATION:\s*(\S+)',
        caseSensitive: false,
      ).firstMatch(text)?.group(1);
      if (location != null) completer.complete(location);
    });
    search('urn:schemas-sony-com:service:ScalarWebAPI:1');
    search('urn:schemas-sony-com:service:DigitalImaging:1');
    search('ssdp:all');
    final location = await completer.future.timeout(
      listenFor,
      onTimeout: () => null,
    );
    await subscription.cancel();
    return location;
  } catch (_) {
    return null;
  } finally {
    socket?.close();
  }
}
