import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:xml/xml.dart';

class SamsungGalaxyStore extends AppSource {
  @override
  String get name => 'Samsung Galaxy Store';

  SamsungGalaxyStore() {
    hosts = [
      'galaxystore.samsung.com',
      'apps.samsung.com',
      'apps.samsung.cn',
      'galaxyappstore.com',
      'apps.galaxyappstore.com',
    ];
    inferAppIdFromUrlPath = false;
    showReleaseDateAsVersionToggle = true;
  }

  DateTime? _parseReleaseDateFromUrl(String apkUrl) {
    final filename = Uri.parse(
      apkUrl,
    ).pathSegments.where((s) => s.isNotEmpty).last;
    final match = RegExp(r'(\d{14,17})').firstMatch(filename);
    if (match == null) return null;
    final ts = match.group(1)!;
    return DateTime(
      int.parse(ts.substring(0, 4)),
      int.parse(ts.substring(4, 6)),
      int.parse(ts.substring(6, 8)),
      int.parse(ts.substring(8, 10)),
      int.parse(ts.substring(10, 12)),
      int.parse(ts.substring(12, 14)),
      ts.length >= 17 ? int.parse(ts.substring(14, 17)) : 0,
    );
  }

  Future<String> _getSdkVersion() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt.toString();
    } catch (e) {
      return '37';
    }
  }

  @override
  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    if (Uri.parse(url).host == 'cn-ms.galaxyappstore.com' && !forAPKDownload) {
      return {
        'Content-Type': 'text/plain; charset=UTF-8',
        'Accept': 'image/webp',
      };
    }
    return null;
  }

  String _odsEnvelope(
    String method,
    String requestId,
    Map<String, String> params,
    Map<String, String> device,
    String identity,
  ) {
    // Samsung's session/transaction IDs use China standard time.
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    String pad(int value) => value.toString().padLeft(2, '0');
    final hour = '${now.year}${pad(now.month)}${pad(now.day)}${pad(now.hour)}';
    final digest = sha256.convert(utf8.encode('$identity${hour}GalaxyApps'));
    final transaction = '${now.day}${digest.toString().substring(0, 7)}';
    final builder = XmlBuilder()
      ..processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'SamsungProtocol',
      attributes: {
        'networkType': '0',
        'version2': '0',
        'lang': 'zh_CN',
        'openApiVersion': device['sdkVer']!,
        'deviceModel': device['deviceId']!,
        'deviceMakerName': 'samsung',
        'deviceMakerType': '0',
        'mcc': device['mcc']!,
        'mnc': device['mnc']!,
        'csc': device['csc']!,
        'odcVersion': '4.6.11.4',
        'storeFilter': 'themeDeviceModel=${device['deviceId']}_TM',
        'supportFeature': '',
        'version': '7.9',
        'filter': '1',
        'odcType': '01',
        'storeMode': '0',
        'cacheVersion': '1',
        'systemId': DateTime.now().millisecondsSinceEpoch.toString(),
        'sessionId': '$transaction$hour${pad(now.minute)}',
        'logId': identity,
        'deviceFeature':
            'locale=zh_CN||abi32=armeabi-v7a:armeabi||abi64=arm64-v8a',
        'userMode': '0',
        'asaaMode': '0',
      },
      nest: () {
        builder.element(
          'request',
          attributes: {
            'name': method,
            'id': requestId,
            'numParam': params.length.toString(),
            'transactionId': transaction,
          },
          nest: () {
            for (final entry in params.entries) {
              builder.element(
                'param',
                attributes: {'name': entry.key},
                nest: entry.value,
              );
            }
          },
        );
      },
    );
    return builder.buildDocument().toXmlString();
  }

  Future<Map<String, String>> _odsRequest(
    String method,
    String requestId,
    Map<String, String> params,
    Map<String, String> device,
    String identity,
    Map<String, dynamic> settings,
  ) async {
    final response = await sourceRequest(
      'https://cn-ms.galaxyappstore.com/ods.as?reqId=$requestId&ot=01&ct=B',
      settings,
      followRedirects: false,
      postBody: _odsEnvelope(method, requestId, params, device, identity),
    );
    ensureHttpSuccess(response);
    final fields = <String, String>{};
    try {
      final document = XmlDocument.parse(utf8.decode(response.bodyBytes));
      if (document.rootElement.name.local != 'SamsungProtocol' ||
          document.children.any((node) => node is XmlDoctype)) {
        throw const FormatException();
      }
      for (final node in document.descendants.whereType<XmlElement>()) {
        if (node.childElements.isNotEmpty) continue;
        final key = node.getAttribute('name') ?? node.name.local;
        if (fields.containsKey(key)) throw const FormatException();
        fields[key] = node.innerText.trim();
        if (key == 'errorString' && node.getAttribute('errorCode') != null) {
          if (fields.containsKey('errorCode')) throw const FormatException();
          fields['errorCode'] = node.getAttribute('errorCode')!;
        }
      }
    } on FormatException {
      throw ObtainiumError(tr('unexpectedStoreApiResponse'), unexpected: true);
    }
    if (fields['errorCode'] != '0') {
      throw ObtainiumError(tr('samsungGalaxyStoreApiError'));
    }
    return fields;
  }

  Future<APKDetails> _getCnOdsDetails(
    String packageName,
    Map<String, String> device,
    Map<String, dynamic> settings,
  ) async {
    final random = Random.secure();
    final identity = List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final identifiers = {
      'imei': identity,
      'extuk': identity,
      'stduk': identity,
    };
    final metadata = await _odsRequest(
      'getDownloadInfo',
      '2298',
      {
        'mode': 'directDownload',
        'guid': packageName,
        'productID': '',
        ...identifiers,
        'predeployed': '0',
        'unifiedPaymentYN': 'Y',
        'lkAppIncludedYN': 'Y',
        'betaTestYN': 'N',
        'minorYN': 'N',
        'stateCode': '',
      },
      device,
      identity,
      settings,
    );
    final productId = metadata['productID'] ?? '';
    final version = metadata['version'] ?? '';
    final versionCode = int.tryParse(metadata['versionCode'] ?? '') ?? 0;
    final metadataSize = int.tryParse(metadata['realContentsSize'] ?? '');
    if (metadata['GUID'] != packageName ||
        productId.isEmpty ||
        version.isEmpty ||
        versionCode <= 0 ||
        (metadata.containsKey('realContentsSize') &&
            (metadataSize == null || metadataSize <= 0)) ||
        !['0', '1'].contains(metadata['needToLogin']) ||
        !['Y', 'N'].contains(metadata['installableYN'])) {
      throw ObtainiumError(tr('unexpectedStoreApiResponse'), unexpected: true);
    }
    if (metadata['needToLogin'] == '1') {
      throw ObtainiumError(tr('samsungGalaxyStoreLoginRequired'));
    }
    if (metadata['installableYN'] != 'Y') throw NoAPKError();
    final grant = await _odsRequest(
      'downloadForRestore',
      '2316',
      {
        'GUID': packageName,
        'productID': productId,
        ...identifiers,
        'downloadType': 'new',
        'autoUpdateYN': 'N',
        'triggeredFrom': 'DETAIL_PAGE',
        'predeployed': '0',
        'deepLinkSource': '',
        'resumeYN': 'N',
      },
      device,
      identity,
      settings,
    );
    final size = int.tryParse(grant['contentsSize'] ?? '') ?? 0;
    if (grant['productID'] != productId ||
        (grant.containsKey('GUID') && grant['GUID'] != packageName) ||
        (grant.containsKey('version') && grant['version'] != version) ||
        (grant.containsKey('versionCode') &&
            int.tryParse(grant['versionCode']!) != versionCode) ||
        size <= 0 ||
        (metadataSize != null && size != metadataSize)) {
      throw ObtainiumError(tr('unexpectedStoreApiResponse'), unexpected: true);
    }
    // downLoadURI is the full APK, including universal 32n64 packages.
    // binaryArch does not indicate whether an APK is a delta.
    final apkUrl = Uri.tryParse(grant['downLoadURI'] ?? '');
    if (apkUrl == null ||
        apkUrl.scheme != 'https' ||
        apkUrl.userInfo.isNotEmpty ||
        apkUrl.port != 443 ||
        apkUrl.pathSegments.where((segment) => segment.isNotEmpty).isEmpty ||
        !['samsungapps.com', 'galaxyappstore.com'].any(
          (host) => apkUrl.host == host || apkUrl.host.endsWith('.$host'),
        )) {
      throw NoAPKError();
    }
    return APKDetails(
      version,
      [MapEntry('$packageName.apk', apkUrl.toString())],
      AppNames(
        name,
        metadata['productName']?.trim().isNotEmpty == true
            ? metadata['productName']!
            : packageName,
      ),
      releaseDate: _parseReleaseDateFromUrl(apkUrl.toString()),
    );
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    final uri = Uri.parse(url);
    final host = uri.host;
    final validHosts = hosts + hosts.map((h) => 'www.$h').toList();
    if (!validHosts.contains(host)) {
      throw InvalidURLError(name)..url = url;
    }
    String? appId;
    if (uri.queryParameters.containsKey('appId')) {
      appId = uri.queryParameters['appId'];
    } else {
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length >= 2) {
        appId = segments.last;
      } else if (segments.isNotEmpty) {
        appId = segments.last;
      }
    }
    if (appId == null || appId.isEmpty) {
      throw InvalidURLError(name)..url = url;
    }
    return 'https://apps.galaxyappstore.com/detail/$appId';
  }

  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    final uri = Uri.parse(standardUrl);
    if (uri.queryParameters.containsKey('appId')) {
      return uri.queryParameters['appId'];
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty) {
      return segments.last;
    }
    return null;
  }

  @override
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems => [
    [
      GeneratedFormTextField(
        'deviceId',
        label: tr('deviceModel'),
        required: false,
        hint: 'SM-S948B',
      ),
    ],
    [
      GeneratedFormTextField(
        'csc',
        label: tr('cscCode'),
        required: false,
        hint: 'DBT',
      ),
    ],
    [
      GeneratedFormTextField(
        'mcc',
        label: tr('mobileCountryCode'),
        required: false,
        hint: '425',
      ),
    ],
    [
      GeneratedFormTextField(
        'mnc',
        label: tr('mobileNetworkCode'),
        required: false,
        hint: '01',
      ),
    ],
  ];

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    final uri = Uri.parse(standardUrl);
    final String packageName;
    if (uri.queryParameters.containsKey('appId')) {
      packageName = uri.queryParameters['appId']!;
    } else {
      packageName = uri.pathSegments.where((s) => s.isNotEmpty).last;
    }
    final deviceId =
        additionalSettings['deviceId']?.toString().isNotEmpty == true
        ? additionalSettings['deviceId'].toString()
        : 'SM-S948B';
    final csc = additionalSettings['csc']?.toString().isNotEmpty == true
        ? additionalSettings['csc'].toString()
        : 'DBT';
    final mcc = additionalSettings['mcc']?.toString().trim() ?? '';
    final mnc = additionalSettings['mnc']?.toString().trim() ?? '';

    final sdkVer = await _getSdkVersion();

    final device = {
      'deviceId': deviceId,
      'csc': csc,
      'sdkVer': sdkVer,
      'mcc': mcc.isEmpty ? '425' : mcc,
      'mnc': mnc.isEmpty ? '01' : mnc,
    };
    try {
      return await _getStubDetails(
        standardUrl,
        packageName,
        device,
        additionalSettings,
      );
    } catch (_) {
      // Only explicitly configured mainland-China apps use the CN service.
      if (csc.toUpperCase() != 'CHC' || device['mcc'] != '460') rethrow;
      return _getCnOdsDetails(packageName, device, additionalSettings);
    }
  }

  Future<APKDetails> _getStubDetails(
    String standardUrl,
    String packageName,
    Map<String, String> device,
    Map<String, dynamic> additionalSettings,
  ) async {
    final String vasUrl =
        Uri.parse('https://vas.samsungapps.com/stub/stubDownload.as')
            .replace(
              queryParameters: {
                'appId': packageName,
                ...device,
                'systemId': '1608665720954',
                'abiType': '64',
                'extuk': '0191d6627f38685f',
              },
            )
            .toString();

    final Response response = await sourceRequest(vasUrl, additionalSettings);
    ensureHttpSuccess(response);
    final String body = response.body;

    final resultCode = RegExp(
      r'<resultCode>(\d+)</resultCode>',
    ).firstMatch(body)?.group(1);
    if (resultCode != '1') {
      final msg = RegExp(
        r'<resultMsg>([^<]*)</resultMsg>',
      ).firstMatch(body)?.group(1);
      throw ObtainiumError(msg ?? tr('samsungGalaxyStoreApiError'));
    }

    final apkMatch = RegExp(
      r'<downloadURI><!\[CDATA\[([^\]]+)\]\]></downloadURI>',
    ).firstMatch(body);
    if (apkMatch == null) {
      throw NoAPKError()..url = standardUrl;
    }
    final String apkUrl = apkMatch.group(1)!;

    final versionMatch = RegExp(
      r'<versionName>([^<]+)</versionName>',
    ).firstMatch(body);
    if (versionMatch == null) {
      throw NoVersionError();
    }
    final String version = versionMatch.group(1)!;

    final nameMatch = RegExp(
      r'<productName>(?:<!\[CDATA\[)?([^<\]]+)(?:\]\]>)?</productName>',
    ).firstMatch(body);
    final String appName = nameMatch?.group(1)?.trim() ?? packageName;

    final DateTime? releaseDate = _parseReleaseDateFromUrl(apkUrl);

    return APKDetails(
      version,
      [MapEntry('$packageName.apk', apkUrl)],
      AppNames(name, appName),
      releaseDate: releaseDate,
    );
  }
}
