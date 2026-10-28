import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/app_list_tile.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/apps_provider.dart';

AppInMemory _app(
  String id, {
  String? installed,
  String latest = '2.0',
  bool pinned = false,
}) => AppInMemory(
  App(
    id: id,
    url: 'https://github.com/example/$id',
    author: 'Example',
    name: id,
    installedVersion: installed,
    latestVersion: latest,
    preferredApkIndex: 0,
    pinned: pinned,
    additionalSettings: const {},
  ),
  null,
  null,
  null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('apps with a pending update are floated to the top of the list', () {
    final ordered = AppListBuilder.reorder(
      [_app('uptodate', installed: '2.0'), _app('stale', installed: '1.0')],
      true,
      false,
      {'stale'},
    );
    expect(ordered.map((e) => e.app.id), ['stale', 'uptodate']);
  });

  test('a user-pinned app outranks a pending update', () {
    final ordered = AppListBuilder.reorder(
      [
        _app('uptodate', installed: '2.0', pinned: true),
        _app('stale', installed: '1.0'),
      ],
      true,
      false,
      {'stale'},
    );
    expect(ordered.map((e) => e.app.id), ['uptodate', 'stale']);
  });

  test('turning pinning off keeps the plain sort order', () {
    final ordered = AppListBuilder.reorder(
      [_app('uptodate', installed: '2.0'), _app('stale', installed: '1.0')],
      false,
      false,
      {'stale'},
    );
    expect(ordered.map((e) => e.app.id), ['uptodate', 'stale']);
  });
}
