import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider_lifecycle.dart';

void main() {
  group('apkPathBelongsToApp', () {
    const appId = 'com.example.app';

    test('matches a plain cached download', () {
      expect(apkPathBelongsToApp('com.example.app-123456.apk', appId), isTrue);
    });

    test('matches an APK unpacked into its bundle folder', () {
      expect(
        apkPathBelongsToApp(
          'com.example.app-123456-dir/base-arm64-v8a.apk',
          appId,
        ),
        isTrue,
      );
    });

    test('ignores files of another app', () {
      expect(apkPathBelongsToApp('com.other.app-99.apk', appId), isFalse);
      // A name that merely starts with the id must not match - the prefix is
      // only the id when followed by the '-' separator.
      expect(apkPathBelongsToApp('com.example.app2-99.apk', appId), isFalse);
    });

    test('ignores a folder that is named after another app', () {
      expect(
        apkPathBelongsToApp('com.other.app-1/base.apk', appId),
        isFalse,
      );
    });
  });
}
