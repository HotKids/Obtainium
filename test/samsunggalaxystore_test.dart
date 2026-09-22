import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/samsunggalaxystore.dart';
import 'package:obtainium/components/generated_form_model.dart';

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
}
