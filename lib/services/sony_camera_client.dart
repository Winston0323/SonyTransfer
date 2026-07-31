import 'dart:async';

import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/camera_item.dart';

/// A child container of a browsed object: a date or DCIM folder on the card.
class _Folder {
  const _Folder(this.id, this.title);
  final String id;
  final String title;
}

/// One `Browse` response.
class _Page {
  const _Page({
    required this.items,
    required this.folders,
    required this.returned,
    required this.total,
  });

  final List<CameraItem> items;
  final List<_Folder> folders;

  /// Children in this response, which a server may cap below what was asked for.
  final int returned;

  /// Children the browsed object holds in total.
  final int total;
}

class CameraException implements Exception {
  CameraException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Talks to a Sony camera sitting in "Send to Smartphone" mode.
///
/// In that mode the body runs a UPnP/DLNA stack over plain HTTP: a standard
/// `ContentDirectory` service for listing the card and a Sony-proprietary
/// `XPushList` service that drives the progress display on the camera itself.
/// Notably this needs none of the PTP-GUID pairing that "Send to Computer"
/// (PTP/IP on port 15740) demands, which is why it can live entirely in Dart.
class SonyCameraClient {
  SonyCameraClient({
    this.host = defaultHost,
    this.port = defaultPort,
    Duration timeout = const Duration(seconds: 15),
    http.Client? client,
  })  : _timeout = timeout,
        _client = client ?? http.Client();

  static const String defaultHost = '192.168.122.1';
  static const int defaultPort = 64321;

  /// Root when the user chose "Copy images on camera" and pre-selected shots.
  static const String pushRoot = 'PushRoot';

  /// Root when the user chose "Copy images on smartphone", exposing the whole card.
  static const String photoRoot = 'PhotoRoot';

  static const String _contentDirectory =
      'urn:schemas-upnp-org:service:ContentDirectory:1';
  static const String _pushList = 'urn:schemas-sony-com:service:XPushList:1';

  final String host;
  final int port;
  final http.Client _client;

  final Duration _timeout;

  String get _base => 'http://$host:$port';

  void close() => _client.close();

  /// Confirms a camera is actually listening, and returns its friendly name.
  Future<String> probe() async {
    final http.Response response;
    try {
      response =
          await _client.get(Uri.parse('$_base/DmsDescPush.xml')).timeout(_timeout);
    } on TimeoutException {
      throw CameraException(
        'No answer from $host:$port. Check that the phone is joined to the '
        "camera's DIRECT-... Wi-Fi network and that the camera is still waiting "
        'to send.',
      );
    } catch (e) {
      throw CameraException('Could not reach $host:$port ($e).');
    }
    if (response.statusCode != 200) {
      throw CameraException(
        'Camera answered HTTP ${response.statusCode} for the device description.',
      );
    }
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(response.body);
    } on XmlException {
      throw CameraException('$host:$port answered, but not like a Sony camera.');
    }
    final name = doc.findAllElements('friendlyName', namespaceUri: '*').firstOrNull;
    return name?.innerText.trim() ?? 'Sony camera';
  }

  /// Puts the camera into its "transferring" display state.
  ///
  /// Returns whether the camera accepted it. The XPushList service only exists
  /// when the user selected images on the camera; in "Select on Smartphone" mode
  /// the camera answers 404. Since this only drives the camera's own display, a
  /// refusal must not stop the transfer.
  Future<bool> transferStart() => _tryPushList('X_TransferStart', '');

  /// Releases the camera from "Send to Smartphone" mode.
  ///
  /// Best-effort for the same reason as [transferStart].
  Future<bool> transferEnd() =>
      _tryPushList('X_TransferEnd', '<ErrCode>0</ErrCode>');

  Future<bool> _tryPushList(String action, String body) async {
    try {
      await _soap(
        path: '/upnp/control/XPushList',
        service: _pushList,
        action: action,
        body: body,
      );
      return true;
    } on CameraException {
      return false;
    }
  }

  /// Children fetched per Browse call.
  ///
  /// Small enough that the first shots reach the screen after one round trip on
  /// the camera's slow radio, large enough that a full card doesn't cost hundreds
  /// of requests.
  static const int pageSize = 60;

  /// Cameras enumerate a card oldest-first, so a recursive walk has to reach the
  /// very end before it sees anything recent. Bail out well past any real card
  /// rather than following a malformed tree forever.
  static const int _maxDepth = 6;

  /// Streams shots newest-first, a page at a time.
  ///
  /// Emitting pages as they arrive is what lets the timeline appear after a single
  /// round trip instead of after the whole card is enumerated, and walking each
  /// container backwards means the page that arrives first is the most recent one
  /// — the shots a user almost always came for.
  Stream<List<CameraItem>> browse({String? root}) async* {
    // Ragged pages would otherwise be able to hand back the same shot twice,
    // since positions are addressed from the end of a list the camera is free to
    // report inconsistently.
    final seen = <String>{};

    await for (final page in _fromRoot(root)) {
      final fresh = page.where((item) => seen.add(item.id)).toList();
      if (fresh.isNotEmpty) yield fresh;
    }
  }

  /// Collects the whole card. Prefer [browse] anywhere a user is waiting.
  Future<List<CameraItem>> listItems({String? root}) async {
    final items = <CameraItem>[];
    await for (final page in browse(root: root)) {
      items.addAll(page);
    }
    return items;
  }

  /// Which root the camera serves depends on the copy mode picked on it: shots
  /// chosen on the camera land under [pushRoot], while "Select on Smartphone"
  /// exposes the card under [photoRoot] and leaves [pushRoot] unserved or empty.
  ///
  /// The candidate's first page doubles as the probe, so deciding costs no extra
  /// round trip.
  Stream<List<CameraItem>> _fromRoot(String? root) async* {
    if (root != null) {
      yield* _walk(root, root, 0);
      return;
    }

    try {
      final push =
          await _browsePage(pushRoot, pushRoot, start: 0, count: pageSize);
      if (push.total > 0) {
        yield* _walkFrom(pushRoot, pushRoot, push, 0);
        return;
      }
    } on CameraException {
      // Not served in this mode.
    }

    yield* _walk(photoRoot, photoRoot, 0);
  }

  Stream<List<CameraItem>> _walk(
    String objectId,
    String folder,
    int depth,
  ) async* {
    if (depth >= _maxDepth) return;
    final first = await _browsePage(objectId, folder, start: 0, count: pageSize);
    yield* _walkFrom(objectId, folder, first, depth);
  }

  Stream<List<CameraItem>> _walkFrom(
    String objectId,
    String folder,
    _Page first,
    int depth,
  ) async* {
    // Step by what the camera actually returned rather than what was asked for,
    // since a server is free to cap a page below RequestedCount and stepping by
    // the larger figure would skip over shots.
    final step = first.returned;
    if (step > 0) {
      for (var start = ((first.total - 1) ~/ step) * step;
          start > 0;
          start -= step) {
        final page =
            await _browsePage(objectId, folder, start: start, count: step);
        yield* _emit(page, depth);
      }
    }

    yield* _emit(first, depth);
  }

  /// Newest-first within a page, recursing into folders as they are met.
  Stream<List<CameraItem>> _emit(_Page page, int depth) async* {
    if (page.items.isNotEmpty) yield page.items.reversed.toList();
    for (final folder in page.folders.reversed) {
      yield* _walk(folder.id, folder.title, depth + 1);
    }
  }

  Future<_Page> _browsePage(
    String objectId,
    String folder, {
    required int start,
    required int count,
  }) async {
    final envelope = await _soap(
      path: '/upnp/control/ContentDirectory',
      service: _contentDirectory,
      action: 'Browse',
      body: '<ObjectID>$objectId</ObjectID>'
          '<BrowseFlag>BrowseDirectChildren</BrowseFlag>'
          '<Filter>*</Filter>'
          '<StartingIndex>$start</StartingIndex>'
          '<RequestedCount>$count</RequestedCount>'
          '<SortCriteria></SortCriteria>',
    );

    final result =
        envelope.findAllElements('Result', namespaceUri: '*').firstOrNull;
    if (result == null) {
      throw CameraException('Browse response for "$objectId" had no Result.');
    }

    // The Result element carries an escaped XML document as its text, so the
    // payload has to be parsed a second time.
    final XmlDocument didl;
    try {
      didl = XmlDocument.parse(result.innerText);
    } on XmlException catch (e) {
      throw CameraException('Browse returned unreadable DIDL-Lite ($e).');
    }

    final folders = <_Folder>[];
    for (final container in didl.findAllElements('container', namespaceUri: '*')) {
      final id = container.getAttribute('id');
      if (id == null) continue;
      final title = container
              .findAllElements('title', namespaceUri: '*')
              .firstOrNull
              ?.innerText ??
          id;
      folders.add(_Folder(id, title));
    }

    final items = <CameraItem>[];
    for (final item in didl.findAllElements('item', namespaceUri: '*')) {
      final parsed = _parseItem(item, folder);
      if (parsed != null) items.add(parsed);
    }

    return _Page(
      items: items,
      folders: folders,
      returned: _intOf(envelope, 'NumberReturned'),
      total: _intOf(envelope, 'TotalMatches'),
    );
  }

  CameraItem? _parseItem(XmlElement item, String folder) {
    final id = item.getAttribute('id');
    if (id == null) return null;
    final title =
        item.findAllElements('title', namespaceUri: '*').firstOrNull?.innerText;
    if (title == null || title.isEmpty) return null;

    final resources = <CameraResource>[];
    for (final res in item.findAllElements('res', namespaceUri: '*')) {
      final url = res.innerText.trim();
      if (url.isEmpty) continue;
      resources.add(
        CameraResource(
          url: url,
          byteSize: int.tryParse(res.getAttribute('size') ?? ''),
          resolution: res.getAttribute('resolution'),
          protocolInfo: res.getAttribute('protocolInfo') ?? '',
        ),
      );
    }
    if (resources.isEmpty) return null;

    final date =
        item.findAllElements('date', namespaceUri: '*').firstOrNull?.innerText;

    return CameraItem(
      id: id,
      title: title,
      folder: folder,
      resources: resources,
      captured: date == null ? null : DateTime.tryParse(date.trim()),
    );
  }

  int _intOf(XmlDocument envelope, String name) {
    final element = envelope.findAllElements(name, namespaceUri: '*').firstOrNull;
    return int.tryParse(element?.innerText.trim() ?? '') ?? 0;
  }

  Future<XmlDocument> _soap({
    required String path,
    required String service,
    required String action,
    required String body,
  }) async {
    final payload =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:$action xmlns:u="$service">$body</u:$action>'
        '</s:Body>'
        '</s:Envelope>';

    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$_base$path'),
            headers: {
              'SOAPACTION': '"$service#$action"',
              'Content-Type': 'text/xml; charset="utf-8"',
            },
            body: payload,
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw CameraException('$action timed out after ${_timeout.inSeconds}s.');
    } catch (e) {
      throw CameraException('$action failed ($e).');
    }

    if (response.statusCode != 200) {
      throw CameraException('$action returned HTTP ${response.statusCode}.');
    }
    try {
      return XmlDocument.parse(response.body);
    } on XmlException catch (e) {
      throw CameraException('$action returned unreadable XML ($e).');
    }
  }
}
