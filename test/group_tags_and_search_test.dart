import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/app_list_tile.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';

App buildApp({
  String id = 'com.example.app',
  String name = 'Example App',
  String author = 'Example Author',
  List<String> categories = const [],
  List<String> groups = const [],
  String? installedVersion = '1.0.0',
  String latestVersion = '1.0.0',
}) => App(
  id: id,
  url: 'https://github.com/example/app',
  author: author,
  name: name,
  installedVersion: installedVersion,
  latestVersion: latestVersion,
  additionalSettings: const {},
  preferredApkIndex: 0,
  categories: categories,
  groups: groups,
);

void main() {
  group('App.groups (grouped list tags)', () {
    test('survives a JSON round trip', () {
      final app = buildApp(categories: ['fun'], groups: ['mine', 'open']);
      final restored = App.fromJson(
        jsonDecode(jsonEncode(app.toJson())) as Map<String, dynamic>,
      );
      expect(restored.groups, ['mine', 'open']);
      expect(restored.categories, ['fun']);
    });

    test('survives the copyWith() that saveApps performs', () {
      final app = buildApp(groups: ['mine']);
      expect(app.copyWith().groups, ['mine']);
    });

    test('defaults to empty for JSON written before the field existed', () {
      final legacy = buildApp(categories: ['mine']).toJson()
        ..remove('groups');
      expect(App.fromJson(legacy).groups, isEmpty);
    });

    // The regression this field exists for: the category editor/selector
    // persists the app with the categories it knows about. While the group tag
    // lived in `categories` that write-back silently deleted it and the app
    // dropped out of its group (most visibly right after opening the app's
    // detail page, which runs an update check and rebuilds the list).
    test('is untouched when the category UI writes categories back', () {
      final app = buildApp(categories: [], groups: ['mine']);
      final afterCategoryEdit = app.copyWith(categories: <String>[]);
      expect(afterCategoryEdit.categories, isEmpty);
      expect(afterCategoryEdit.groups, ['mine']);
    });

    test('a group filter matches on groups, never on categories', () {
      final inGroup = buildApp(groups: ['mine']);
      final sameCategoryNameButNoGroup = buildApp(categories: ['mine']);
      expect(inGroup.groups.contains('mine'), isTrue);
      expect(sameCategoryNameButNoGroup.groups.contains('mine'), isFalse);
    });
  });

  group('app list search query', () {
    final settingsProvider = SettingsProvider();
    final apps = [
      AppInMemory(
        buildApp(id: 'com.wirelessalien.zipxtract', name: 'ZipXtract', author: 'WirelessAlien'),
        null,
        null,
        null,
      ),
      AppInMemory(
        buildApp(id: 'org.b3log.siyuan', name: '思源笔记', author: 'B3log'),
        null,
        null,
        null,
      ),
    ];

    List<String> match(String query) => AppListBuilder.filter(
      apps,
      AppsFilter(searchQuery: query),
      settingsProvider,
    ).map((e) => e.app.id).toList();

    test('matches on name, case insensitively', () {
      expect(match('zipxtract'), ['com.wirelessalien.zipxtract']);
    });

    test('matches on author', () {
      expect(match('b3log'), ['org.b3log.siyuan']);
    });

    test('matches on app id', () {
      expect(match('siyuan'), ['org.b3log.siyuan']);
    });

    test('every token has to match something', () {
      expect(match('wirelessalien zipxtract'), [
        'com.wirelessalien.zipxtract',
      ]);
      // "zipxtract" matches on name, but "b3log" matches nothing in that app.
      expect(match('zipxtract b3log'), isEmpty);
    });

    test('an empty query keeps everything, and the filter sheet no longer '
        'carries name/author/ID fields', () {
      expect(match(''), hasLength(2));
      expect(AppsFilter().toFormValuesMap().keys, [
        'upToDateApps',
        'nonInstalledApps',
        'sourceFilter',
      ]);
    });

    test('a partially filled filter sheet never hides apps', () {
      final filter = AppsFilter();
      filter.setFormValuesFromMap(const {});
      expect(filter.includeUptodate, isTrue);
      expect(filter.includeNonInstalled, isTrue);
    });
  });
}
