import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/repository_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsProvider {
  _Settings(this.address);
  String address;
  @override
  String get lanRepoUrl => address;
}

class _Repo extends FDroidRepo {
  @override
  String get sourceIdentifier => 'FDroidRepo';
  Map<String, dynamic> packages = {};
  bool offline = false;
  String? xml;
  final requests = <String>[];
  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requests.add(url);
    if (offline) throw StateError('offline');
    if (xml != null) {
      return Response(
        url.endsWith('index.xml') ? xml! : '',
        url.endsWith('index.xml') ? 200 : 404,
        request: Request('GET', Uri.parse(url)),
      );
    }
    return Response.bytes(
      utf8.encode(jsonEncode({'packages': packages})),
      200,
      request: Request('GET', Uri.parse(url)),
      headers: {'content-type': 'application/json'},
    );
  }
}

Map<String, dynamic> _package(
  String name, {
  int version = 1,
  List<String>? groups,
}) => {
  'metadata': {
    'name': {'en-US': name},
    'summary': {'en-US': 'From repository'},
    'categories': groups ?? <String>[],
  },
  'versions': {
    'hash': {
      'manifest': {'versionName': '$version.0', 'versionCode': version},
      'file': {'name': '/app-$version.apk'},
    },
  },
};

App _app(String id, {bool managed = true, bool installed = false}) => App(
  id: id,
  url: 'https://github.com/example/shared',
  author: 'User',
  name: 'Custom',
  latestVersion: '1.0',
  preferredApkIndex: 0,
  installedVersion: installed ? '1.0' : null,
  pinned: true,
  groups: managed ? ['old-group'] : [],
  additionalSettings: {
    'repositoryManaged': managed,
    'appName': 'User name',
    'allowedSigningCertHashes': 'kept',
  },
);

RepositoryCatalog _catalog(List<App> apps, {bool cached = false}) =>
    RepositoryCatalog(
      baseUrl: 'http://repo',
      fetchedAt: DateTime(2026, 10, 18),
      apps: apps,
      fromCache: cached,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Settings settings;
  late _Repo repo;
  late RepositoryCatalogService service;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = _Settings('http://repo');
    settings.prefs = await SharedPreferences.getInstance();
    repo = _Repo();
    service = RepositoryCatalogService(
      settings,
      repo: repo,
      resolveBaseUrl: () async =>
          settings.address.isEmpty ? 'http://discovered' : settings.address,
    );
  });

  test('legacy XML supplies the catalog and its groups', () async {
    repo.xml =
        '<fdroid><application id="com.example.xml"><name>XML App</name>'
        '<category>Tools</category><package><version>3.0</version><versioncode>3</versioncode>'
        '<apkname>xml.apk</apkname></package></application></fdroid>';
    final result = await service.load();
    expect(result.apps.single.id, 'com.example.xml');
    expect(result.apps.single.groups, ['Tools']);
    expect(result.apps.single.apkUrls.single.value, 'http://repo/xml.apk');
  });

  test(
    'HTML error pages cannot replace a good catalog with an empty one',
    () async {
      repo.packages = {'com.example.app': _package('App')};
      await service.load();
      repo.xml = '<html><body>Server error</body></html>';
      final result = await service.load();
      expect(result.fromCache, isTrue);
      expect(result.apps.single.id, 'com.example.app');
    },
  );

  test(
    'a corrupt offline cache reports failure without providing an empty catalog',
    () async {
      await settings.prefs!.setString(
        RepositoryCatalogService.cacheKey,
        '{broken',
      );
      repo.offline = true;
      await expectLater(service.load(), throwsA(isA<ObtainiumError>()));
    },
  );

  test('known installed package identity migrates a legacy placeholder', () {
    final old = _app('100000000001').copyWith(
      additionalSettings: {'installedPackageName': 'com.example.real'},
    );
    final plan = planCatalogMerge(_catalog([_app('com.example.real')]), [
      (app: old, installed: true),
    ], {});
    expect(plan.remove, {'100000000001'});
    expect(plan.save.single.id, 'com.example.real');
    expect(plan.save.single.pinned, isTrue);
  });

  test(
    'catalog lists actual packages, including different IDs with the same name',
    () async {
      repo.packages = {
        'com.example.one': _package('Anki', groups: ['学习']),
        'com.example.two': _package('Anki'),
      };
      final result = await service.load();
      expect(result.fromCache, isFalse);
      expect(result.apps.map((app) => app.id), [
        'com.example.one',
        'com.example.two',
      ]);
      expect(result.apps.first.groups, ['学习']);
      expect(result.apps.first.url, 'http://repo/?appId=com.example.one');
      expect(result.apps.first.apkUrls.single.value, 'http://repo/app-1.apk');
      expect(result.apps.first.overrideSource, 'FDroidRepo');
      expect(repo.requests, ['http://repo/index-v2.json']);
    },
  );

  test('offline restart uses the last successful persisted catalog', () async {
    repo.packages = {'com.example.new': _package('New app', version: 2)};
    final online = await service.load();
    repo.offline = true;
    final restarted = RepositoryCatalogService(
      settings,
      repo: repo,
      resolveBaseUrl: () async => throw StateError('discovery failed'),
    );
    final cached = await restarted.load();
    expect(cached.fromCache, isTrue);
    expect(cached.fetchedAt, online.fetchedAt);
    expect(cached.apps.single.id, 'com.example.new');
    expect(cached.apps.single.latestVersion, '2.0');
    expect(cached.apps.single.apkUrls.single.value, 'http://repo/app-2.apk');
  });

  test(
    'offline without a cache reports failure instead of built-in defaults',
    () async {
      repo.offline = true;
      await expectLater(service.load(), throwsA(isA<ObtainiumError>()));
      expect(
        settings.prefs!.getString(RepositoryCatalogService.cacheKey),
        isNull,
      );
      expect(
        repo.requests.every((url) => url.startsWith('http://repo/')),
        isTrue,
      );
    },
  );

  test(
    'switching configured repository cannot reuse an unrelated cache',
    () async {
      repo.packages = {'com.example.old': _package('Old')};
      await service.load();
      settings.address = 'http://another-repo';
      repo.offline = true;
      await expectLater(service.load(), throwsA(isA<ObtainiumError>()));
    },
  );

  test(
    'automatic discovery refreshes catalog addresses after an IP change',
    () async {
      settings.address = '';
      repo.packages = {'com.example.app': _package('App')};
      await service.load();
      final changed = RepositoryCatalogService(
        settings,
        repo: repo,
        resolveBaseUrl: () async => 'http://new-ip',
      );
      expect(
        (await changed.load()).apps.single.apkUrls.single.value,
        'http://new-ip/app-1.apk',
      );
    },
  );

  test(
    'partially malformed indexes preserve the last successful snapshot',
    () async {
      repo.packages = {'com.example.app': _package('Good')};
      await service.load();
      final before = settings.prefs!.getString(
        RepositoryCatalogService.cacheKey,
      );
      repo.packages = {
        'com.example.app': _package('Good'),
        'com.example.broken': {'metadata': {}},
      };
      final result = await service.load();
      expect(result.fromCache, isTrue);
      expect(
        settings.prefs!.getString(RepositoryCatalogService.cacheKey),
        before,
      );
    },
  );

  test(
    'an empty valid repository replaces the cache and removes only managed uninstalled apps',
    () async {
      repo.packages = {'com.example.app': _package('App')};
      await service.load();
      repo.packages = {};
      final empty = await service.load();
      expect(empty.fromCache, isFalse);
      expect(empty.apps, isEmpty);
      final plan = planCatalogMerge(empty, [
        (app: _app('com.example.remove'), installed: false),
        (app: _app('com.example.installed', installed: true), installed: true),
        (app: _app('com.example.manual', managed: false), installed: false),
      ], {});
      expect(plan.remove, {'com.example.remove'});
    },
  );

  test('offline cache prunes entries absent from its repository snapshot', () {
    expect(
      planCatalogMerge(_catalog([], cached: true), [
        (app: _app('com.example.keep'), installed: false),
      ], {}).remove,
      {'com.example.keep'},
    );
  });

  test(
    'merge preserves user settings while repository metadata and APKs refresh',
    () async {
      repo.packages = {'com.example.app': _package('Repo name', version: 2)};
      final plan = planCatalogMerge(await service.load(), [
        (app: _app('com.example.app'), installed: true),
      ], {});
      final app = plan.save.single;
      expect(app.pinned, isTrue);
      expect(app.additionalSettings['appName'], 'User name');
      expect(app.additionalSettings['allowedSigningCertHashes'], 'kept');
      expect(app.name, 'Repo name');
      expect(app.latestVersion, '2.0');
      expect(app.url, 'http://repo/?appId=com.example.app');
    },
  );

  test(
    'a published package takes over the hand-added row that tracked it remotely',
    () async {
      repo.packages = {'com.example.manual': _package('Repo name')};
      final plan = planCatalogMerge(await service.load(), [
        (app: _app('com.example.manual', managed: false), installed: false),
      ], {});
      expect(plan.save.single.url, 'http://repo/?appId=com.example.manual');
      expect(plan.save.single.overrideSource, 'FDroidRepo');
      expect(plan.save.single.additionalSettings['repositoryManaged'], isTrue);
      expect(plan.save.single.pinned, isTrue);
    },
  );

  test(
    'a manual app the repository does not publish keeps its own source',
    () async {
      repo.packages = {'com.example.other': _package('Other')};
      final manual = _app('com.example.manual', managed: false);
      final plan = planCatalogMerge(await service.load(), [
        (app: manual, installed: false),
      ], {});
      expect(plan.save.map((app) => app.id), ['com.example.other']);
      expect(
        shouldRemoveCatalogApp(
          manual,
          installed: false,
          publishedIds: {'com.example.other'},
        ),
        isFalse,
      );
    },
  );

  test(
    'package deletion remains suppressed after repository address changes',
    () async {
      repo.packages = {'com.example.app': _package('App')};
      settings.address = 'http://changed';
      final plan = planCatalogMerge(await service.load(), [], {
        catalogSuppressionKey('com.example.app'),
      });
      expect(plan.save, isEmpty);
      expect(plan.suppressed, 1);
    },
  );

  test(
    'legacy uninstalled grouped entries are removed, installed entries are retained',
    () {
      final legacy = _app('100000000001').copyWith(additionalSettings: {});
      expect(
        shouldRemoveCatalogApp(legacy, installed: false, publishedIds: {}),
        isTrue,
      );
      expect(
        shouldRemoveCatalogApp(legacy, installed: true, publishedIds: {}),
        isFalse,
      );
    },
  );
}
