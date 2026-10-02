import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/samsunggalaxystore.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:xml/xml.dart';

class _OdsGalaxyStore extends SamsungGalaxyStore {
  final List<Object> responses;
  final requests = <({Uri uri, Object? body, bool followRedirects})>[];

  _OdsGalaxyStore(this.responses);

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requests.add((
      uri: Uri.parse(url),
      body: postBody,
      followRedirects: followRedirects,
    ));
    final response = responses.removeAt(0);
    if (response is Response) return response;
    throw response;
  }
}

Response _ods(Map<String, String> fields, {String code = '0'}) {
  final builder = XmlBuilder();
  builder.element(
    'SamsungProtocol',
    nest: () {
      builder.element(
        'errorInfo',
        nest: () {
          builder.element('errorString', attributes: {'errorCode': code});
        },
      );
      for (final field in fields.entries) {
        builder.element(
          'value',
          attributes: {'name': field.key},
          nest: field.value,
        );
      }
    },
  );
  return Response(
    builder.buildDocument().toXmlString(),
    200,
    headers: {'content-type': 'text/xml; charset=utf-8'},
  );
}

const _metadata = {
  'GUID': 'com.samsung.android.app.sreminder',
  'productID': '000009060570',
  'productName': '三星生活助手',
  'version': '9.4.02.7',
  'versionCode': '940207000',
  'needToLogin': '0',
  'installableYN': 'Y',
  'realContentsSize': '106232505',
};
const _grant = {
  'productID': '000009060570',
  'contentsSize': '106232505',
  'binaryArch': '32n64',
  'downLoadURI':
      'https://cdnet-dn.galaxyappstore.com/App_20260923000000.apk?token=temporary',
  'deltaDownloadURI': 'https://cdnet-dn.galaxyappstore.com/delta.apk',
};
const _china = {
  'deviceId': 'SM-S9480',
  'csc': 'CHC',
  'mcc': '460',
  'mnc': '00',
};

class _RecordingGalaxyStore extends SamsungGalaxyStore {
  late Uri requestUri;

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requestUri = Uri.parse(url);
    return Response('''
<result>
<resultCode>1</resultCode>
<productName>Samsung Assistant</productName>
<versionName>9.4.02.7</versionName>
<downloadURI><![CDATA[https://apps.samsungapps.com/app_20260923000000.apk]]></downloadURI>
</result>
''', 200);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url =
      'https://apps.galaxyappstore.com/detail/com.samsung.android.app.sreminder';

  test('keeps existing network defaults for unset or blank settings', () async {
    for (final value in [null, '', '   ']) {
      final source = _RecordingGalaxyStore();
      await source.getLatestAPKDetails(url, {'mcc': ?value, 'mnc': ?value});
      expect(source.requestUri.queryParameters['mcc'], '425');
      expect(source.requestUri.queryParameters['mnc'], '01');
      expect(source.requestUri.queryParameters['deviceId'], 'SM-S948B');
      expect(source.requestUri.queryParameters['csc'], 'DBT');
    }
  });

  test('uses per-app China settings and preserves MNC leading zeros', () async {
    final source = _RecordingGalaxyStore();
    final result = await source.getLatestAPKDetails(url, {
      'deviceId': 'SM-S9480',
      'csc': 'CHC',
      'mcc': ' 460 ',
      'mnc': ' 00 ',
    });

    expect(source.requestUri.host, 'vas.samsungapps.com');
    expect(source.requestUri.path, '/stub/stubDownload.as');
    expect(source.requestUri.queryParameters, containsPair('mcc', '460'));
    expect(source.requestUri.queryParameters, containsPair('mnc', '00'));
    expect(source.requestUri.queryParameters, containsPair('csc', 'CHC'));
    expect(
      source.requestUri.queryParameters,
      containsPair('deviceId', 'SM-S9480'),
    );
    expect(
      source.requestUri.queryParameters,
      containsPair('appId', 'com.samsung.android.app.sreminder'),
    );
    expect(result.version, '9.4.02.7');
    expect(result.apkUrls.single.key, 'com.samsung.android.app.sreminder.apk');
  });

  test('allows either network code to be overridden independently', () async {
    final source = _RecordingGalaxyStore();
    await source.getLatestAPKDetails(url, {'mcc': '310'});
    expect(source.requestUri.queryParameters['mcc'], '310');
    expect(source.requestUri.queryParameters['mnc'], '01');

    await source.getLatestAPKDetails(url, {'mnc': '001'});
    expect(source.requestUri.queryParameters['mcc'], '425');
    expect(source.requestUri.queryParameters['mnc'], '001');
  });

  test('exposes optional network code text fields in the app settings', () {
    final fields = SamsungGalaxyStore()
        .additionalSourceAppSpecificSettingFormItems
        .expand((row) => row)
        .whereType<GeneratedFormTextField>();
    for (final key in ['mcc', 'mnc']) {
      final field = fields.singleWhere((field) => field.key == key);
      expect(field.required, isFalse);
      expect(field.value, '');
    }
  });

  test(
    'CN stub failure uses ODS metadata then full APK authorization',
    () async {
      final source = _OdsGalaxyStore([
        Response('<result><resultCode>0</resultCode></result>', 200),
        _ods(_metadata),
        _ods(_grant),
      ]);
      final result = await source.getLatestAPKDetails(url, _china);
      expect(result.version, '9.4.02.7');
      expect(result.names.name, '三星生活助手');
      expect(result.apkUrls.single.value, _grant['downLoadURI']);
      expect(result.releaseDate, DateTime(2026, 9, 23));
      expect(source.requests.length, 3); // No APK bytes requested here.
      expect(source.requests.first.uri.host, 'vas.samsungapps.com');
      final identities = <String>{};
      for (var i = 1; i < 3; i++) {
        final request = source.requests[i];
        expect(request.uri.host, 'cn-ms.galaxyappstore.com');
        expect(request.followRedirects, isFalse);
        final id = i == 1 ? '2298' : '2316';
        expect(request.uri.queryParameters['reqId'], id);
        final document = XmlDocument.parse(request.body as String);
        final root = document.rootElement;
        expect(root.getAttribute('deviceModel'), 'SM-S9480');
        expect(root.getAttribute('mcc'), '460');
        expect(root.getAttribute('mnc'), '00');
        expect(root.getAttribute('csc'), 'CHC');
        final envelope = root.getElement('request')!;
        expect(envelope.getAttribute('id'), id);
        final params = {
          for (final p in envelope.childElements)
            p.getAttribute('name')!: p.innerText,
        };
        expect(int.parse(envelope.getAttribute('numParam')!), params.length);
        identities.addAll([
          params['imei']!,
          params['extuk']!,
          params['stduk']!,
        ]);
        expect(
          params[i == 1 ? 'guid' : 'GUID'],
          'com.samsung.android.app.sreminder',
        );
        if (i == 2) expect(params['productID'], '000009060570');
      }
      expect(identities.length, 1);
      expect(identities.single, matches(RegExp(r'^[a-f0-9]{16}$')));
    },
  );

  test(
    'CN HTTP failure also falls back; default and non-CN settings do not',
    () async {
      final cn = _OdsGalaxyStore([
        Response('Unavailable', 503),
        _ods(_metadata),
        _ods(_grant),
      ]);
      expect((await cn.getLatestAPKDetails(url, _china)).version, '9.4.02.7');
      final disconnected = _OdsGalaxyStore([
        const SocketException('stub unavailable'),
        _ods(_metadata),
        _ods(_grant),
      ]);
      expect(
        (await disconnected.getLatestAPKDetails(url, _china)).version,
        '9.4.02.7',
      );
      for (final settings in [
        <String, dynamic>{},
        {'csc': 'XAA', 'mcc': '310'},
        {'csc': 'CHC'},
      ]) {
        final source = _OdsGalaxyStore([
          Response('<result><resultCode>0</resultCode></result>', 200),
        ]);
        await expectLater(
          source.getLatestAPKDetails(url, settings),
          throwsA(isA<ObtainiumError>()),
        );
        expect(source.requests.length, 1);
      }
    },
  );

  test(
    'login, unavailable and mismatched metadata never request authorization',
    () async {
      for (final changes in [
        {'needToLogin': '1'},
        {'installableYN': 'N'},
        {'needToLogin': ''},
        {'GUID': 'com.other.app'},
        {'productID': ''},
        {'version': ''},
        {'versionCode': '0'},
        {'realContentsSize': 'invalid'},
      ]) {
        final source = _OdsGalaxyStore([
          Response('Unavailable', 503),
          _ods({..._metadata, ...changes}),
        ]);
        await expectLater(
          source.getLatestAPKDetails(url, _china),
          throwsA(isA<ObtainiumError>()),
        );
        expect(source.requests.length, 2);
      }
    },
  );

  test(
    'rejects mismatched authorization and non-Samsung download URLs',
    () async {
      for (final changes in [
        {'productID': '99999'},
        {'GUID': 'com.other.app'},
        {'version': '1.0'},
        {'versionCode': '1'},
        {'contentsSize': '1'},
        {'contentsSize': '0'},
        {'downLoadURI': ''},
        {'downLoadURI': 'http://cdnet-dn.galaxyappstore.com/a.apk'},
        {'downLoadURI': 'https://galaxyappstore.com.evil.test/a.apk'},
        {'downLoadURI': 'https://user@cdnet-dn.galaxyappstore.com/a.apk'},
      ]) {
        final source = _OdsGalaxyStore([
          Response('Unavailable', 503),
          _ods(_metadata),
          _ods({..._grant, ...changes}),
        ]);
        await expectLater(
          source.getLatestAPKDetails(url, _china),
          throwsA(isA<ObtainiumError>()),
        );
        expect(source.requests.length, 3);
      }
    },
  );

  test('rejects ODS failures and malformed or ambiguous XML', () async {
    final valid = _ods(_metadata).body;
    for (final response in [
      _ods({}, code: '1000'),
      Response('<html>error</html>', 200),
      Response(
        valid.replaceFirst(
          '</SamsungProtocol>',
          '<value name="GUID">com.other.app</value></SamsungProtocol>',
        ),
        200,
        headers: {'content-type': 'text/xml; charset=utf-8'},
      ),
      Response('<SamsungProtocol>', 200),
      Response(
        '<!DOCTYPE SamsungProtocol>$valid',
        200,
        headers: {'content-type': 'text/xml; charset=utf-8'},
      ),
    ]) {
      final source = _OdsGalaxyStore([Response('Unavailable', 503), response]);
      await expectLater(
        source.getLatestAPKDetails(url, _china),
        throwsA(isA<ObtainiumError>()),
      );
      expect(source.requests.length, 2);
    }
  });

  test('ODS headers do not affect stub or APK downloads', () async {
    final source = SamsungGalaxyStore();
    expect(
      await source.getRequestHeaders(
        {},
        'https://cn-ms.galaxyappstore.com/ods.as',
      ),
      containsPair('Content-Type', 'text/plain; charset=UTF-8'),
    );
    expect(
      await source.getRequestHeaders(
        {},
        'https://vas.samsungapps.com/stub/stubDownload.as',
      ),
      isNull,
    );
    expect(
      await source.getRequestHeaders(
        {},
        _grant['downLoadURI']!,
        forAPKDownload: true,
      ),
      isNull,
    );
  });
}
