import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme.dart';
import 'package:provider/provider.dart';

/// The app detail page's bottom action bar (secondary icons on the left,
/// "Open" and the primary button on the right) used to be wider than the
/// screen on a phone, so the primary button was cut off by the screen edge.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDetailPage(
    WidgetTester tester, {
    required double width,
    double textScale = 1.0,
  }) async {
    // Render on a phone-sized surface.
    tester.view.physicalSize = Size(width * 2, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final settings = SettingsProvider();
    final apps = AppsProvider(settingsProvider: settings);
    final app = AppInMemory(
      const App(
        id: 'com.example.app',
        url: 'https://github.com/example/app',
        author: 'Example Author',
        name: 'Example',
        installedVersion: '1.0.0',
        latestVersion: '1.1.0',
        preferredApkIndex: 0,
        additionalSettings: {},
      ),
      null,
      null,
      null,
    );
    apps.apps[app.app.id] = app;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AppsProvider>.value(value: apps),
          Provider<NotificationsProvider>(
            create: (_) => NotificationsProvider(),
          ),
          Provider<SourceProvider>(create: (_) => SourceProvider()),
        ],
        child: MaterialApp(
          theme: buildObtainiumTheme(
            ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
            'Roboto',
          ),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: AppPage(appId: app.app.id),
          ),
        ),
      ),
    );
    await tester.pump();
    // The page schedules a short one-shot timer; let it fire so the test
    // teardown does not complain about a pending timer.
    await tester.pump(const Duration(seconds: 3));
  }

  for (final scale in [1.0, 1.5]) {
    testWidgets('detail action bar fits on screen, text scale $scale', (
      tester,
    ) async {
      await pumpDetailPage(tester, width: 360, textScale: scale);

      expect(
        tester.takeException(),
        isNull,
        reason: 'the action bar overflowed the screen',
      );

      // The primary button must be fully on screen.
      final primary = tester.getRect(
        find.byIcon(Icons.system_update_alt_rounded),
      );
      expect(primary.right, lessThanOrEqualTo(360));
      expect(primary.left, greaterThanOrEqualTo(0));
    });
  }
}
