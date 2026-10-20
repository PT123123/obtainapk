import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/app_list_tile.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/theme.dart';
import 'package:provider/provider.dart';

/// Guards the app-list grid layout: the card holds an icon row, the app
/// name, the author line and the version/action row. When the grid was
/// squeezed into three columns on a phone, the card was only ~107dp wide and
/// ~118dp tall, so the trailing buttons (version label + download button)
/// fell outside the card and were clipped away by the card's own clip.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppInMemory appNamed(String name) => AppInMemory(
    App(
      id: 'com.example.app',
      url: 'https://github.com/example/app',
      author: 'Example Author',
      name: name,
      installedVersion: '1.0.0',
      latestVersion: '1.1.0',
      preferredApkIndex: 0,
      additionalSettings: const {},
    ),
    null,
    null,
    null,
  );

  Future<void> pumpGrid(
    WidgetTester tester, {
    required String name,
    required double width,
    double textScale = 1.0,
  }) async {
    final settings = SettingsProvider();
    final apps = AppsProvider(settingsProvider: settings);
    final app = appNamed(name);
    apps.apps[app.app.id] = app;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AppsProvider>.value(value: apps),
        ],
        child: MaterialApp(
          theme: buildObtainiumTheme(
            ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
            'Roboto',
          ),
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(
                textScaler: TextScaler.linear(textScale),
              ),
              child: SizedBox(
                width: width,
                child: Builder(
                  builder: (context) => CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        sliver: SliverGrid(
                          // Same delegate the app list uses.
                          gridDelegate: appGridDelegate(context, width - 24),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) => Card(
                              clipBehavior: Clip.antiAlias,
                              child: AppListTile(
                                appInMemory: app,
                                settingsProvider: settings,
                                appsProvider: apps,
                                multiSelected: false,
                                detailSelected: false,
                                autofocus: false,
                                onTap: () {},
                                onToggleSelected: () {},
                                grid: true,
                              ),
                            ),
                            childCount: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Both the download button and the "more" menu must sit completely inside
  /// the card, otherwise they are cut off.
  void expectButtonsInsideCard(WidgetTester tester) {
    final card = tester.getRect(find.byType(Card));
    for (final icon in [Icons.download_rounded, Icons.more_vert_rounded]) {
      final button = tester.getRect(find.byIcon(icon));
      expect(
        button.left,
        greaterThanOrEqualTo(card.left - 0.5),
        reason: '$icon sticks out on the left of the card',
      );
      expect(
        button.right,
        lessThanOrEqualTo(card.right + 0.5),
        reason: '$icon sticks out on the right of the card',
      );
      expect(
        button.top,
        greaterThanOrEqualTo(card.top - 0.5),
        reason: '$icon sticks out above the card',
      );
      expect(
        button.bottom,
        lessThanOrEqualTo(card.bottom + 0.5),
        reason: '$icon sticks out below the card',
      );
    }
  }

  test('a phone-sized screen keeps two grid columns', () {
    // 360dp screen, 24dp of horizontal padding.
    expect(appGridColumnCount(336), 2);
    // 393dp screen.
    expect(appGridColumnCount(369), 2);
    // Tablets get more columns, but never narrower than the card minimum.
    expect(appGridColumnCount(576), 3);
    expect(appGridColumnCount(1200), 6);
  });

  testWidgets('the card height budget covers the card content', (
    tester,
  ) async {
    for (final scale in [1.0, 1.3, 1.5, 2.0]) {
      final settings = SettingsProvider();
      final apps = AppsProvider(settingsProvider: settings);
      final app = appNamed(
        'A Very Long Application Name That Wraps Onto Two Lines',
      );
      apps.apps[app.app.id] = app;

      late double budget;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ChangeNotifierProvider<AppsProvider>.value(value: apps),
          ],
          child: MaterialApp(
            theme: buildObtainiumTheme(
              ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
              'Roboto',
            ),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Builder(
                  builder: (context) {
                    budget = appGridCardHeight(context);
                    return CustomScrollView(
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          sliver: SliverGrid(
                            // A very tall cell: the card content is top
                            // aligned, so the action row's bottom reveals how
                            // tall the content actually is.
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                  mainAxisExtent: 900,
                                ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) => Card(
                                clipBehavior: Clip.antiAlias,
                                child: AppListTile(
                                  appInMemory: app,
                                  settingsProvider: settings,
                                  appsProvider: apps,
                                  multiSelected: false,
                                  detailSelected: false,
                                  autofocus: false,
                                  onTap: () {},
                                  onToggleSelected: () {},
                                  grid: true,
                                ),
                              ),
                              childCount: 1,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final card = tester.getRect(find.byType(Card));
      final actionRow = tester.getRect(find.byIcon(Icons.download_rounded));
      // Card padding is 10dp on top and bottom.
      final natural = actionRow.bottom - card.top + 10;
      // ignore: avoid_print
      print('scale $scale -> content: $natural, budget: $budget');
      expect(
        natural,
        lessThanOrEqualTo(budget),
        reason: 'the card content is taller than the grid cell allows',
      );
    }
  });

  testWidgets('grid card shows its buttons in full on a phone', (tester) async {
    tester.view.physicalSize = const Size(1080, 2376);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpGrid(tester, name: 'Example', width: 360);

    expect(tester.takeException(), isNull, reason: 'the card overflowed');
    expectButtonsInsideCard(tester);
  });

  testWidgets('grid card shows its buttons in full with a long name', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2376);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpGrid(
      tester,
      name: 'A Very Long Application Name That Wraps Onto Two Lines',
      width: 360,
    );

    expect(tester.takeException(), isNull, reason: 'the card overflowed');
    expectButtonsInsideCard(tester);
  });

  testWidgets('grid card shows its buttons in full with a large system font', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2376);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpGrid(tester, name: 'Example', width: 360, textScale: 1.5);

    expect(tester.takeException(), isNull, reason: 'the card overflowed');
    expectButtonsInsideCard(tester);
  });

  testWidgets('grid card shows its buttons in full on a tablet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await pumpGrid(tester, name: 'Example', width: 1280);

    expect(tester.takeException(), isNull, reason: 'the card overflowed');
    expectButtonsInsideCard(tester);
  });
}
