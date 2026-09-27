import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';

void main() {
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
}
