import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sony_transfer/services/scalar_camera.dart';
import 'package:sony_transfer/services/shot_ingest.dart';

void main() {
  const endpoint = 'http://192.168.122.1:8080/sony/camera';

  ScalarCamera camera(http.Client client) => ScalarCamera(
        endpoint: Uri.parse(endpoint),
        client: client,
        ownsClient: false,
      );

  test('description XML points at the camera service', () {
    const xml = '''
<?xml version="1.0"?>
<root xmlns:av="urn:schemas-sony-com:av">
  <device>
    <friendlyName>ILCE-7RM3</friendlyName>
    <av:X_ScalarWebAPI_ServiceList>
      <av:X_ScalarWebAPI_Service>
        <av:X_ScalarWebAPI_ServiceType>guide</av:X_ScalarWebAPI_ServiceType>
        <av:X_ScalarWebAPI_ActionList_URL>http://192.168.122.1:8080/sony</av:X_ScalarWebAPI_ActionList_URL>
      </av:X_ScalarWebAPI_Service>
      <av:X_ScalarWebAPI_Service>
        <av:X_ScalarWebAPI_ServiceType>camera</av:X_ScalarWebAPI_ServiceType>
        <av:X_ScalarWebAPI_ActionList_URL>http://192.168.122.1:8080/sony/</av:X_ScalarWebAPI_ActionList_URL>
      </av:X_ScalarWebAPI_Service>
    </av:X_ScalarWebAPI_ServiceList>
  </device>
</root>
''';
    expect(
      cameraEndpointFromDescription(xml).toString(),
      endpoint,
    );
    expect(friendlyNameFromDescription(xml), 'ILCE-7RM3');
  });

  test('direct probe stops at the first port that speaks the API', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), endpoint);
      return http.Response(
        jsonEncode({
          'result': [
            ['getAvailableApiList', 'startLiveview', 'awaitTakePicture'],
          ],
          'id': 1,
        }),
        200,
      );
    });

    final found = await discoverScalarCamera(
      hosts: ['192.168.122.1'],
      client: client,
      useSsdp: false,
    );
    expect(found.endpoint.toString(), endpoint);
    expect(found.apis, contains('awaitTakePicture'));
  });

  test('a busy shutter wait is retryable and not a failed session', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'error': [40403, ''],
          'id': 1,
        }),
        200,
      ),
    );
    expect(await camera(client).awaitNextPicture(), isEmpty);
  });

  test('Original is chosen ahead of the 2M preview', () async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      switch (body['method']) {
        case 'getSupportedPostviewImageSize':
          return http.Response(
            jsonEncode({
              'result': [
                ['2M', 'Original', 'VGA'],
              ],
              'id': 1,
            }),
            200,
          );
        case 'setPostviewImageSize':
          expect(body['params'], ['Original']);
          return http.Response(jsonEncode({'result': [0], 'id': 1}), 200);
        default:
          return http.Response('{}', 500);
      }
    });

    expect(
      await camera(client).preparePostview(const [
        'setPostviewImageSize',
        'getSupportedPostviewImageSize',
      ]),
      'Original',
    );
  });

  test('picture events keep the larger JPEG and ignore the live view', () {
    final urls = pictureUrlsInEvents([
      {
        'type': 'liveviewStatus',
        'url': 'http://192.168.122.1:8080/liveview/liveviewstream',
      },
      {
        'type': 'takePicture',
        'takePictureUrl': [
          'http://192.168.122.1:8080/postview/small.jpg',
          'http://192.168.122.1:8080/postview/DSC00021.JPG',
        ],
      },
    ]);
    expect(
      pickShotUrl(urls),
      'http://192.168.122.1:8080/postview/DSC00021.JPG',
    );
    expect(
      fileNameFromCameraUrl(Uri.parse(pickShotUrl(urls)!)),
      'DSC00021.JPG',
    );
  });

  test('live view open prefers the large stream', () async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['method'], 'startLiveviewWithSize');
      expect(body['params'], ['L']);
      return http.Response(
        jsonEncode({
          'result': ['http://192.168.122.1:8080/liveview/liveviewstream'],
          'id': 1,
        }),
        200,
      );
    });
    expect(
      await camera(client).openLiveView(const [
        'startLiveview',
        'startLiveviewWithSize',
      ]),
      'http://192.168.122.1:8080/liveview/liveviewstream',
    );
  });
}
