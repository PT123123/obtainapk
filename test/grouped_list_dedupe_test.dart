import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/apps_provider.dart';

void main() {
  test(
    'URL merge preserves different package IDs from the same repository',
    () {
      expect(
        shouldMergeListAppByUrl(
          storedId: 'com.ichi2.anki',
          listId: 'com.pt123123.ankiplus',
        ),
        isFalse,
      );
      expect(
        shouldMergeListAppByUrl(
          storedId: '100000000001',
          listId: 'com.pt123123.ankiplus',
        ),
        isTrue,
      );
      expect(
        shouldMergeListAppByUrl(
          storedId: 'com.pt123123.ankiplus',
          listId: '100000000001',
        ),
        isTrue,
      );
    },
  );
  group('resolveSameUrlDuplicates (grouped-list merge repair)', () {
    // The regression: installing a placeholder-ID app renames its ID to the
    // real package name, and the next startup merge re-added the placeholder
    // — the same URL appeared twice in the app list.
    test('keeps the real-ID entry and drops the placeholder shadowing it', () {
      final (keeper, remove) = resolveSameUrlDuplicates([
        '100000000010',
        'com.pt123123.quire',
      ], (id) => RegExp(r'^[0-9]+$').hasMatch(id));
      expect(keeper, 'com.pt123123.quire');
      expect(remove, ['100000000010']);
    });

    test('keeps the real-ID entry regardless of position', () {
      final (keeper, remove) = resolveSameUrlDuplicates([
        'com.pt123123.quire',
        '100000000010',
      ], (id) => RegExp(r'^[0-9]+$').hasMatch(id));
      expect(keeper, 'com.pt123123.quire');
      expect(remove, ['100000000010']);
    });

    test('drops extras when every entry is still a placeholder', () {
      final (keeper, remove) = resolveSameUrlDuplicates([
        '100000000010',
        '100000000099',
      ], (id) => RegExp(r'^[0-9]+$').hasMatch(id));
      expect(keeper, '100000000010');
      expect(remove, ['100000000099']);
    });

    test('never touches two real IDs (one repo, two packages)', () {
      final (keeper, remove) = resolveSameUrlDuplicates([
        'com.example.one',
        'com.example.two',
      ], (id) => RegExp(r'^[0-9]+$').hasMatch(id));
      expect(remove, isEmpty);
      expect(keeper, 'com.example.one');
    });

    test('single entry is never removed', () {
      final (keeper, remove) = resolveSameUrlDuplicates([
        '100000000010',
      ], (id) => RegExp(r'^[0-9]+$').hasMatch(id));
      expect(keeper, '100000000010');
      expect(remove, isEmpty);
    });
  });

  group('shouldAdoptListAppId (list.json package-ID rename)', () {
    test('placeholder adopts the real package ID', () {
      expect(
        shouldAdoptListAppId(
          storedId: '100000000001',
          listId: 'com.pt123123.ankiplus',
          storedInstalled: false,
          listIdAlreadyTracked: false,
        ),
        isTrue,
      );
    });
    test('does not adopt another real package even when uninstalled', () {
      expect(
        shouldAdoptListAppId(
          storedId: 'com.ichi2.anki',
          listId: 'com.pt123123.ankiplus',
          storedInstalled: false,
          listIdAlreadyTracked: false,
        ),
        isFalse,
      );
    });

    test('same id is not an adoption', () {
      expect(
        shouldAdoptListAppId(
          storedId: 'com.x.y',
          listId: 'com.x.y',
          storedInstalled: false,
          listIdAlreadyTracked: false,
        ),
        isFalse,
      );
    });

    test('never re-points an app that is installed under the stored id', () {
      expect(
        shouldAdoptListAppId(
          storedId: 'com.ichi2.anki',
          listId: 'com.pt123123.ankiplus',
          storedInstalled: true,
          listIdAlreadyTracked: false,
        ),
        isFalse,
      );
    });

    test('never re-points when the new id is already tracked elsewhere', () {
      expect(
        shouldAdoptListAppId(
          storedId: 'com.ichi2.anki',
          listId: 'com.pt123123.ankiplus',
          storedInstalled: false,
          listIdAlreadyTracked: true,
        ),
        isFalse,
      );
    });

    test(
      'a numeric/12-hex placeholder in list.json is not adopted as an id',
      () {
        expect(
          shouldAdoptListAppId(
            storedId: 'com.real.pkg',
            listId: '100000000009',
            storedInstalled: false,
            listIdAlreadyTracked: false,
          ),
          isFalse,
        );
        expect(
          shouldAdoptListAppId(
            storedId: 'com.real.pkg',
            listId: 'a1b2c3d4e5f6',
            storedInstalled: false,
            listIdAlreadyTracked: false,
          ),
          isFalse,
        );
      },
    );
  });

  group('list removals (apps the user deleted must stay deleted)', () {
    // The regression: list.json was merged on every startup, so an app removed
    // from the app list came back on the next launch.
    App trackedApp(String url, List<String> groups) => App(
      id: 'com.example.app',
      url: url,
      author: 'example',
      name: 'Example',
      latestVersion: '',
      preferredApkIndex: 0,
      additionalSettings: const {},
      groups: groups,
    );

    test('only grouped (list-sourced) apps are recorded when removed', () {
      expect(
        groupedListUrlsOf([
          trackedApp('https://github.com/PT123123/bitwardendroid', ['mine']),
          trackedApp('https://github.com/example/hand-added', []),
        ]),
        ['https://github.com/PT123123/bitwardendroid'],
      );
    });

    test('a removal keeps skipping the app while it is untracked', () {
      expect(
        resolveListSuppression(
          suppressed: ['https://github.com/PT123123/bitwardendroid'],
          trackedUrls: {'https://github.com/PT123123/quire-compose'},
        ),
        ['https://github.com/PT123123/bitwardendroid'],
      );
    });

    test('a removal is forgotten once the URL is tracked again', () {
      expect(
        resolveListSuppression(
          suppressed: ['https://github.com/PT123123/bitwardendroid'],
          trackedUrls: {'https://github.com/PT123123/bitwardendroid'},
        ),
        isEmpty,
      );
    });
  });
}
