import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';

void main() {
  group('FDroidRepo.findAppsByExactName', () {
    test(
      'matches a repository slug to a unique package ID component',
      () async {
        final repo = _FixtureRepo(_index(['dev.pt123123.awandroid']));

        final matches = await repo.findAppsByExactName('http://lan-repo', [
          'aw-android-native',
        ], const {});

        expect(matches.single.key, 'dev.pt123123.awandroid');
        expect(matches.single.value, 'ActivityWatch');
      },
    );

    test('keeps exact display-name matching', () async {
      final repo = _FixtureRepo(_index(['com.mibandhub.app']));

      final matches = await repo.findAppsByExactName('http://lan-repo', [
        '手环管家',
      ], const {});

      expect(matches.single.key, 'com.mibandhub.app');
    });

    test('does not guess when a fuzzy package match is ambiguous', () async {
      final repo = _FixtureRepo(
        _index(['dev.pt123123.awandroid', 'com.example.awandroid']),
      );

      final matches = await repo.findAppsByExactName('http://lan-repo', [
        'aw-android-native',
      ], const {});

      expect(matches, isEmpty);
    });
  });
}

class _FixtureRepo extends FDroidRepo {
  _FixtureRepo(this._body);

  final String _body;

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async => Response.bytes(
    utf8.encode(_body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
    request: Request('GET', Uri.parse(url)),
  );
}

String _index(List<String> packageIds) => jsonEncode({
  'packages': {
    for (final id in packageIds)
      id: {
        'metadata': {
          'name': {
            'en-US': id == 'com.mibandhub.app' ? '手环管家' : 'ActivityWatch',
          },
        },
        'versions': {
          'hash': {
            'manifest': {'versionName': '1.0', 'versionCode': 1},
            'file': {'name': '/$id.apk'},
          },
        },
      },
  },
});
