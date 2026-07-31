import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sony_transfer/models/camera_item.dart';
import 'package:sony_transfer/services/sony_camera_client.dart';

String _escape(String xml) => xml
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Wraps DIDL-Lite the way the camera does: as an escaped XML document sitting
/// inside the `Result` element of a SOAP envelope.
String _browseResponse(
  String didl, {
  required int numberReturned,
  required int totalMatches,
}) =>
    '<?xml version="1.0"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
    '<s:Body>'
    '<u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">'
    '<Result>${_escape(didl)}</Result>'
    '<NumberReturned>$numberReturned</NumberReturned>'
    '<TotalMatches>$totalMatches</TotalMatches>'
    '<UpdateID>1</UpdateID>'
    '</u:BrowseResponse>'
    '</s:Body>'
    '</s:Envelope>';

String _didl(String inner) =>
    '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">$inner</DIDL-Lite>';

const String _jpegItem = '''
<item id="0001" parentID="PushRoot" restricted="1">
  <dc:title>DSC00001.JPG</dc:title>
  <dc:date>2026-07-30T18:24:05</dc:date>
  <upnp:class>object.item.imageItem.photo</upnp:class>
  <res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_TN" resolution="160x120">http://192.168.122.1:60152/tn.jpg</res>
  <res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_SM" resolution="640x480">http://192.168.122.1:60152/sm.jpg</res>
  <res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG" resolution="1616x1080">http://192.168.122.1:60152/lrg.jpg</res>
  <res protocolInfo="http-get:*:image/jpeg:*" resolution="7952x5304" size="42000000">http://192.168.122.1:60152/orig.jpg</res>
</item>''';

const String _rawItem = '''
<item id="0002" parentID="PushRoot" restricted="1">
  <dc:title>DSC00002.ARW</dc:title>
  <upnp:class>object.item.imageItem.photo</upnp:class>
  <res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_TN" resolution="160x120">http://192.168.122.1:60152/raw_tn.jpg</res>
  <res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG" resolution="1616x1080">http://192.168.122.1:60152/raw_lrg.jpg</res>
</item>''';

/// A JPEG whose title omits the extension, which some bodies do.
const String _untitledExtensionItem = '''
<item id="0003" parentID="PushRoot" restricted="1">
  <dc:title>DSC00003</dc:title>
  <res protocolInfo="http-get:*:image/jpeg:*" resolution="7952x5304" size="1000">http://192.168.122.1:60152/DSC00003.JPG</res>
</item>''';

String? _tagOf(String body, String tag) =>
    RegExp('<$tag>(.*?)</$tag>').firstMatch(body)?.group(1);

/// Most assertions care about a particular shot rather than its position, since
/// arrival order is now newest-first rather than the camera's own order.
CameraItem _named(List<CameraItem> items, String title) =>
    items.firstWhere((item) => item.title == title);

/// A page of [count] JPEGs numbered from [from], oldest first, the way a camera
/// enumerates a card.
String _numberedItems(int from, int count) => [
      for (var i = from; i < from + count; i++)
        '<item id="${i.toString().padLeft(4, '0')}" parentID="folder" restricted="1">'
            '<dc:title>DSC${i.toString().padLeft(5, '0')}.JPG</dc:title>'
            '<res protocolInfo="http-get:*:image/jpeg:*" size="1000">'
            'http://192.168.122.1:60152/$i.jpg</res>'
            '</item>',
    ].join();

void main() {
  group('listItems', () {
    test('reads items out of the doubly-encoded Browse payload', () async {
      final client = SonyCameraClient(
        client: MockClient((request) async {
          return http.Response(
            _browseResponse(
              _didl(_jpegItem + _rawItem),
              numberReturned: 2,
              totalMatches: 2,
            ),
            200,
          );
        }),
      );

      final items = await client.listItems();

      final jpeg = _named(items, 'DSC00001.JPG');

      expect(items, hasLength(2));
      expect(jpeg.fileName, 'DSC00001.JPG');
      expect(jpeg.isRawOnly, isFalse);
      expect(jpeg.original!.url, endsWith('orig.jpg'));
      expect(jpeg.byteSize, 42000000);
      expect(jpeg.original!.resolution, '7952x5304');
    });

    test('reads the capture date, and tolerates its absence', () async {
      final client = SonyCameraClient(
        client: MockClient((request) async {
          return http.Response(
            _browseResponse(
              _didl(_jpegItem + _untitledExtensionItem),
              numberReturned: 2,
              totalMatches: 2,
            ),
            200,
          );
        }),
      );

      final items = await client.listItems();

      expect(
        _named(items, 'DSC00001.JPG').captured,
        DateTime(2026, 7, 30, 18, 24, 5),
      );
      expect(_named(items, 'DSC00003').captured, isNull);
    });

    test('picks renditions for the grid tile and the preview', () async {
      final client = SonyCameraClient(
        client: MockClient((request) async {
          return http.Response(
            _browseResponse(
              _didl(_jpegItem + _rawItem),
              numberReturned: 2,
              totalMatches: 2,
            ),
            200,
          );
        }),
      );

      final items = await client.listItems();

      final jpeg = _named(items, 'DSC00001.JPG');
      final raw = _named(items, 'DSC00002.ARW');

      expect(jpeg.thumbnail!.url, endsWith('sm.jpg'));
      expect(jpeg.preview!.url, endsWith('lrg.jpg'));

      // The raw shot offers no _SM, so the tile has to fall back to _TN.
      expect(raw.thumbnail!.url, endsWith('raw_tn.jpg'));
      expect(raw.preview!.url, endsWith('raw_lrg.jpg'));
    });

    test('treats a shot with no sized rendition as raw-only', () async {
      final client = SonyCameraClient(
        client: MockClient((request) async {
          return http.Response(
            _browseResponse(
              _didl(_rawItem),
              numberReturned: 1,
              totalMatches: 1,
            ),
            200,
          );
        }),
      );

      final items = await client.listItems();

      expect(items, hasLength(1));
      expect(items.single.isRawOnly, isTrue);
      expect(items.single.original, isNull);
    });

    test('borrows the extension from the URL when the title lacks one',
        () async {
      final client = SonyCameraClient(
        client: MockClient((request) async {
          return http.Response(
            _browseResponse(
              _didl(_untitledExtensionItem),
              numberReturned: 1,
              totalMatches: 1,
            ),
            200,
          );
        }),
      );

      final items = await client.listItems();

      expect(items.single.fileName, 'DSC00003.JPG');
    });

    test('keeps paging until TotalMatches is covered', () async {
      var browseCalls = 0;

      final client = SonyCameraClient(
        client: MockClient((request) async {
          browseCalls++;
          final startingIndex =
              int.parse(_tagOf(request.body, 'StartingIndex')!);
          final item = startingIndex == 0 ? _jpegItem : _untitledExtensionItem;
          return http.Response(
            _browseResponse(
              _didl(item),
              numberReturned: 1,
              totalMatches: 2,
            ),
            200,
          );
        }),
      );

      final items = await client.listItems();

      expect(browseCalls, 2);
      // Reversed against the camera's own order: the newest shot comes first.
      expect(items.map((i) => i.fileName),
          ['DSC00003.JPG', 'DSC00001.JPG']);
    });

    test('descends into folder containers and records the folder name',
        () async {
      final client = SonyCameraClient(
        client: MockClient((request) async {
          final objectId = _tagOf(request.body, 'ObjectID');
          if (objectId == SonyCameraClient.pushRoot) {
            return http.Response(
              _browseResponse(
                _didl(
                  '<container id="folder1" parentID="PushRoot" restricted="1">'
                  '<dc:title>100MSDCF</dc:title></container>',
                ),
                numberReturned: 1,
                totalMatches: 1,
              ),
              200,
            );
          }
          return http.Response(
            _browseResponse(
              _didl(_jpegItem),
              numberReturned: 1,
              totalMatches: 1,
            ),
            200,
          );
        }),
      );

      final items = await client.listItems();

      expect(items, hasLength(1));
      expect(items.single.folder, '100MSDCF');
    });

    test('falls back to PhotoRoot when PushRoot is not being served', () async {
      final requestedRoots = <String>[];

      final client = SonyCameraClient(
        client: MockClient((request) async {
          final objectId = _tagOf(request.body, 'ObjectID')!;
          requestedRoots.add(objectId);
          if (objectId == SonyCameraClient.pushRoot) {
            return http.Response('no such object', 500);
          }
          return http.Response(
            _browseResponse(
              _didl(_jpegItem),
              numberReturned: 1,
              totalMatches: 1,
            ),
            200,
          );
        }),
      );

      final items = await client.listItems();

      expect(requestedRoots,
          [SonyCameraClient.pushRoot, SonyCameraClient.photoRoot]);
      expect(items, hasLength(1));
    });
  });

  group('browse', () {
    /// A card of [total] shots served in pages of [pageSize], oldest first.
    MockClient card({required int total, int pageSize = 60}) =>
        MockClient((request) async {
          final start = int.parse(_tagOf(request.body, 'StartingIndex')!);
          final count = int.parse(_tagOf(request.body, 'RequestedCount')!);
          final returned =
              (total - start).clamp(0, count < pageSize ? count : pageSize);
          return http.Response(
            _browseResponse(
              _didl(_numberedItems(start, returned)),
              numberReturned: returned,
              totalMatches: total,
            ),
            200,
          );
        });

    test('hands over the newest shots first', () async {
      final client = SonyCameraClient(client: card(total: 150));

      final first = await client.browse().first;

      // 150 shots in pages of 60 puts the newest at index 149, on the page
      // starting at 120.
      expect(first.first.title, 'DSC00149.JPG');
      expect(first.last.title, 'DSC00120.JPG');
    });

    test('emits the first page long before the card is enumerated', () async {
      var browseCalls = 0;
      final client = SonyCameraClient(
        client: MockClient((request) async {
          browseCalls++;
          final start = int.parse(_tagOf(request.body, 'StartingIndex')!);
          final returned = (3000 - start).clamp(0, 60);
          return http.Response(
            _browseResponse(
              _didl(_numberedItems(start, returned)),
              numberReturned: returned,
              totalMatches: 3000,
            ),
            200,
          );
        }),
      );

      await client.browse().first;

      // The whole card is 50 pages. Waiting for it before showing anything is
      // the slowness this streaming API exists to avoid.
      expect(browseCalls, 2);
    });

    test('still delivers every shot exactly once', () async {
      final client = SonyCameraClient(client: card(total: 150));

      final items = await client.listItems();

      expect(items, hasLength(150));
      expect(items.map((i) => i.id).toSet(), hasLength(150));
      expect(items.first.title, 'DSC00149.JPG');
      expect(items.last.title, 'DSC00000.JPG');
    });

    test('steps by the page size the camera actually honours', () async {
      // Asked for 60, gives 25. Stepping by the requested figure would skip
      // shots; stepping by the returned one must not.
      final client = SonyCameraClient(client: card(total: 80, pageSize: 25));

      final items = await client.listItems();

      expect(items, hasLength(80));
      expect(items.map((i) => i.id).toSet(), hasLength(80));
    });

    test('drops duplicates from a camera that pages inconsistently', () async {
      // Reports 3 shots but serves the same page whatever the index, which is
      // what ragged paging looks like from the client's side.
      final client = SonyCameraClient(
        client: MockClient((request) async {
          return http.Response(
            _browseResponse(
              _didl(_numberedItems(0, 2)),
              numberReturned: 2,
              totalMatches: 3,
            ),
            200,
          );
        }),
      );

      final items = await client.listItems();

      expect(items.map((i) => i.id), ['0001', '0000']);
    });

    test('gives up on a tree that never bottoms out', () async {
      // A container whose child is another container, forever.
      final client = SonyCameraClient(
        client: MockClient((request) async {
          return http.Response(
            _browseResponse(
              _didl(
                '<container id="deeper" parentID="x" restricted="1">'
                '<dc:title>deeper</dc:title></container>',
              ),
              numberReturned: 1,
              totalMatches: 1,
            ),
            200,
          );
        }),
      );

      await expectLater(client.listItems(), completion(isEmpty));
    });
  });

  group('probe', () {
    test('returns the camera friendly name', () async {
      final client = SonyCameraClient(
        client: MockClient((request) async {
          expect(request.url.path, '/DmsDescPush.xml');
          return http.Response(
            '<?xml version="1.0"?>'
            '<root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
            '<friendlyName>ILCE-7RM3</friendlyName>'
            '</device></root>',
            200,
          );
        }),
      );

      expect(await client.probe(), 'ILCE-7RM3');
    });

    test('reports a helpful message when nothing is listening', () async {
      final client = SonyCameraClient(
        client: MockClient((request) async => http.Response('nope', 404)),
      );

      expect(
        () => client.probe(),
        throwsA(isA<CameraException>()),
      );
    });

    test('gives up on a silent address once the timeout elapses', () async {
      final client = SonyCameraClient(
        timeout: const Duration(milliseconds: 50),
        client: MockClient((request) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return http.Response('too late', 200);
        }),
      );

      await expectLater(client.probe(), throwsA(isA<CameraException>()));
    });
  });

  group('transfer control', () {
    test('sends the Sony XPushList SOAP actions', () async {
      final actions = <String>[];

      final client = SonyCameraClient(
        client: MockClient((request) async {
          actions.add(request.headers['SOAPACTION']!);
          expect(request.url.path, '/upnp/control/XPushList');
          return http.Response(
            '<?xml version="1.0"?>'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
            '<s:Body/></s:Envelope>',
            200,
          );
        }),
      );

      await client.transferStart();
      await client.transferEnd();

      expect(actions, [
        '"urn:schemas-sony-com:service:XPushList:1#X_TransferStart"',
        '"urn:schemas-sony-com:service:XPushList:1#X_TransferEnd"',
      ]);
    });

    test('survives a camera with no XPushList service', () async {
      // "Select on Smartphone" mode does not serve XPushList, so the camera
      // answers 404. The display state is cosmetic and must not break the run.
      final client = SonyCameraClient(
        client: MockClient((request) async => http.Response('Not Found', 404)),
      );

      expect(await client.transferStart(), isFalse);
      expect(await client.transferEnd(), isFalse);
    });

    test('reports success when the service is present', () async {
      final client = SonyCameraClient(
        client: MockClient((request) async => http.Response(
              '<?xml version="1.0"?>'
              '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
              '<s:Body/></s:Envelope>',
              200,
            )),
      );

      expect(await client.transferStart(), isTrue);
    });
  });
}
