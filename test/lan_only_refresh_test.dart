import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/near_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsProvider {
  _Settings(this.address, {this.remoteEnabled = false});
  final String address;
  final bool remoteEnabled;
  @override
  String get lanRepoUrl => address;
  @override
  bool get githubSourceEnabled => remoteEnabled;
}

Map<String, dynamic> _deviceInfo() => {
  for (final key in [
    'board',
    'bootloader',
    'brand',
    'device',
    'display',
    'fingerprint',
    'hardware',
    'host',
    'id',
    'manufacturer',
    'model',
    'product',
    'tags',
    'type',
  ])
    key: 'test',
  'version': {
    'baseOS': '',
    'codename': '',
    'incremental': '',
    'previewSdkInt': 0,
    'release': '14',
    'sdkInt': 34,
    'securityPatch': '',
  },
  'isPhysicalDevice': true,
  'isLowRamDevice': false,
  'freeDiskSize': 0,
  'totalDiskSize': 0,
  'physicalRamSize': 0,
  'availableRamSize': 0,
  'systemFeatures': <String>[],
};

// Exercise the production fetchUpdate path without starting platform services.
class _Apps extends Fake implements AppsProvider {
  _Apps(this.settingsProvider, App app)
    : apps = {app.id: AppInMemory(app, null, null, null)};
  @override
  final SettingsProvider settingsProvider;
  @override
  final Map<String, AppInMemory> apps;
  @override
  CancellationToken registerDownloadCancellation(String appId) =>
      CancellationToken();
  @override
  void clearDownloadCancellation(String appId) {}
  @override
  void notify() {}
}

App _app({bool legacyRemote = false}) => App(
  id: 'com.example.local',
  url: 'https://github.com/example/local',
  author: 'example',
  name: 'Local',
  latestVersion: '1.0',
  preferredApkIndex: 0,
  additionalSettings: {'useRemoteSource': legacyRemote},
);

// Record every HTTP destination, refusing external traffic before it is sent.
class _LocalClient extends Fake implements HttpClient {
  _LocalClient(this.delegate, this.requests);
  final HttpClient delegate;
  final List<Uri> requests;
  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  set badCertificateCallback(
    bool Function(X509Certificate, String, int)? callback,
  ) => delegate.badCertificateCallback = callback;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    requests.add(url);
    if (url.host != '127.0.0.1') {
      throw StateError('Unexpected external request: $url');
    }
    return delegate.openUrl(method, url);
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}

class _LocalHttp extends HttpOverrides {
  final requests = <Uri>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _LocalClient(super.createHttpClient(context), requests);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/device_info'),
        (_) async => _deviceInfo(),
      );
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('known package takes precedence over stale cached matches', () {
    expect(
      NearSource.packageOf(
        _app().copyWith(
          additionalSettings: {
            'installedPackageName': 'com.example.fork',
            'nearSourcePackageId': 'com.example.fork',
          },
        ),
      ),
      'com.example.local',
    );
  });

  test(
    'global switch overrides legacy app flags and invalid LAN addresses',
    () {
      for (final address in ['', 'http://127.0.0.1:8080', 'invalid-address']) {
        for (final legacyRemote in [false, true]) {
          expect(
            NearSource(
              _Settings(address),
            ).isUsedFor(_app(legacyRemote: legacyRemote)),
            isTrue,
          );
          expect(
            NearSource(
              _Settings(address, remoteEnabled: true),
            ).isUsedFor(_app(legacyRemote: legacyRemote)),
            isFalse,
          );
        }
      }
    },
  );

  test('LAN metadata and APK URLs come from the repository', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'packages': {
            'com.example.local': {
              'metadata': {
                'name': {'en-US': 'Local'},
              },
              'versions': {
                'hash': {
                  'manifest': {'versionName': '2.0', 'versionCode': 2},
                  'file': {'name': '/com.example.local_2.apk'},
                },
              },
            },
          },
        }),
      );
      await request.response.close();
    });
    final address = 'http://127.0.0.1:${server.port}';
    final network = _LocalHttp();
    await HttpOverrides.runWithHttpOverrides(() async {
      final result = await NearSource(
        _Settings(address),
      ).resolve(_app(legacyRemote: true));
      expect(result.apk.version, '2.0');
      expect(
        result.apk.apkUrls.single.value,
        '$address/com.example.local_2.apk',
      );
    }, network);
    expect(network.requests, isNotEmpty);
    expect(network.requests.every((url) => url.host == '127.0.0.1'), isTrue);
  });

  test('refresh of a missing LAN package never queries GitHub', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"packages":{}}');
      await request.response.close();
    });
    final app = _app(legacyRemote: true);
    final provider = _Apps(_Settings('http://127.0.0.1:${server.port}'), app);
    final network = _LocalHttp();
    await HttpOverrides.runWithHttpOverrides(() async {
      await expectLater(
        provider.fetchUpdate(app.id),
        throwsA(
          isA<ObtainiumError>().having(
            (e) => e.code,
            'code',
            'NEAR_SOURCE_APP_NOT_FOUND',
          ),
        ),
      );
    }, network);
    expect(network.requests, isNotEmpty);
    expect(network.requests.every((url) => url.host == '127.0.0.1'), isTrue);
  });

  test('refresh with an unreachable LAN repo never queries GitHub', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final address = 'http://127.0.0.1:${server.port}';
    await server.close(force: true);
    final app = _app(legacyRemote: true);
    final provider = _Apps(_Settings(address), app);
    final network = _LocalHttp();
    await HttpOverrides.runWithHttpOverrides(() async {
      await expectLater(provider.fetchUpdate(app.id), throwsA(anything));
    }, network);
    expect(network.requests, isNotEmpty);
    expect(network.requests.every((url) => url.host == '127.0.0.1'), isTrue);
  });

  test('download resolves LAN before using a stale remote APK URL', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"packages":{}}');
      await request.response.close();
    });
    final app = _app().copyWith(
      apkUrls: const [
        MapEntry(
          'old.apk',
          'https://github.com/example/local/releases/old.apk',
        ),
      ],
    );
    final provider = _Apps(_Settings('http://127.0.0.1:${server.port}'), app);
    final network = _LocalHttp();
    await HttpOverrides.runWithHttpOverrides(() async {
      await expectLater(
        provider.downloadApp(app, null),
        throwsA(
          isA<ObtainiumError>().having(
            (e) => e.code,
            'code',
            'NEAR_SOURCE_APP_NOT_FOUND',
          ),
        ),
      );
    }, network);
    expect(network.requests, isNotEmpty);
    expect(network.requests.every((url) => url.host == '127.0.0.1'), isTrue);
    expect(provider.apps[app.id]!.downloadProgress, isNull);
  });

  test('known package never resolves to a similarly named fork', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'packages': {
            'com.example.fork': {
              'metadata': {
                'name': {'en-US': 'Local'},
              },
              'versions': {
                'hash': {
                  'manifest': {'versionName': '2.0', 'versionCode': 2},
                  'file': {'name': '/fork.apk'},
                },
              },
            },
          },
        }),
      );
      await request.response.close();
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await expectLater(
        NearSource(
          _Settings('http://127.0.0.1:${server.port}'),
        ).resolve(_app()),
        throwsA(
          isA<ObtainiumError>().having(
            (e) => e.code,
            'code',
            'NEAR_SOURCE_APP_NOT_FOUND',
          ),
        ),
      );
    }, _LocalHttp());
  });
}
