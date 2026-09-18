import 'dart:async';
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/utils/native_features.dart';
import 'package:obtainium/pages/home.dart';
import 'package:obtainium/theme.dart';
import 'package:obtainium/utils/dynamic_color_utils.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:workmanager/workmanager.dart';

List<MapEntry<Locale, String>> supportedLocales = const [
  MapEntry(Locale('en'), 'English'),
  MapEntry(Locale('zh', 'Hant_TW'), '臺灣話'),
  MapEntry(Locale('zh'), '简体中文'),
  MapEntry(Locale('it'), 'Italiano'),
  MapEntry(Locale('ja'), '日本語'),
  MapEntry(Locale('hu'), 'Magyar'),
  MapEntry(Locale('de'), 'Deutsch'),
  MapEntry(Locale('fa'), 'فارسی'),
  MapEntry(Locale('fr'), 'Français'),
  MapEntry(Locale('es'), 'Español'),
  MapEntry(Locale('pl'), 'Polski'),
  MapEntry(Locale('ru'), 'Русский'),
  MapEntry(Locale('bs'), 'Bosanski'),
  MapEntry(Locale('pt', 'BR'), 'Brasileiro'),
  MapEntry(Locale('pt'), 'Português'),
  MapEntry(Locale('cs'), 'Česky'),
  MapEntry(Locale('sv'), 'Svenska'),
  MapEntry(Locale('nl'), 'Nederlands'),
  MapEntry(Locale('vi'), 'Tiếng Việt'),
  MapEntry(Locale('tr'), 'Türkçe'),
  MapEntry(Locale('uk'), 'Українська'),
  MapEntry(Locale('da'), 'Dansk'),
  MapEntry(Locale('en', 'EO'), 'Esperanto'),
  MapEntry(Locale('id'), 'Bahasa Indonesia'),
  MapEntry(Locale('ko'), '한국어'),
  MapEntry(Locale('ca'), 'Català'),
  MapEntry(Locale('ar'), 'العربية'),
  MapEntry(Locale('ml'), 'മലയാളം'),
  MapEntry(Locale('gl'), 'Galego'),
];
const fallbackLocale = Locale('en');

/// Default URL of the grouped app list (list.json) pulled on every startup.
/// ObtainAPK merges its groups into the user's app list and tags each app with
/// its group id. Overridable at runtime via the `groupedListUrl` shared-prefs
/// key if a fork needs a different source.
const String defaultGroupedListUrl =
    'https://raw.githubusercontent.com/PT123123/obtainapk/main/list.json';
final Set<Locale> supportedLocaleSet = supportedLocales
    .map((e) => e.key)
    .toSet();
const localeDir = 'assets/translations';
bool isFdroidBuild = false;

const String _unexpectedErrorText = 'An unexpected error occurred.';
const String _closeText = 'Close';

/// Global navigator key, used to navigate from outside the widget tree
/// (e.g. tapping a notification).
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Unique task name used by WorkManager for periodic background update checks.
const _workManagerTaskName = 'obtainiumBgUpdateCheck';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppLogger.init();
    try {
      AppLogger.info('WorkManager callback invoked (task: $taskName)');
      final taskId = 'wm_${DateTime.now().millisecondsSinceEpoch}';
      await bgUpdateCheck(taskId, inputData);
      AppLogger.info('WorkManager callback completed successfully');
      return true;
    } catch (e, stack) {
      AppLogger.error(
        e,
        stackTrace: stack,
        message: 'WorkManager callback crashed',
      );
      return false;
    }
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.init();

  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.error(
      error,
      stackTrace: stack,
      message: 'Uncaught platform error',
    );
    return true;
  };

  // Exceptions thrown in UI handlers are reported to FlutterError.onError
  // rather than PlatformDispatcher.onError, so hook both into the log store.
  final prevFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    prevFlutterErrorHandler?.call(details);
    AppLogger.error(
      details.exception,
      stackTrace: details.stack,
      message: 'Uncaught framework error',
    );
  };

  final settingsProvider = SettingsProvider();
  final sourceProvider = SourceProvider();
  final appsProvider = AppsProvider(settingsProvider: settingsProvider);
  final np = NotificationsProvider();
  await np.initialize();

  await initializeDateFormatting();
  await EasyLocalization.ensureInitialized();

  ErrorWidget.builder = (details) {
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 64),
                SizedBox(height: 16),
                Text(_unexpectedErrorText),
                SizedBox(height: 16),
                FilledButton(
                  onPressed: SystemNavigator.pop,
                  child: Text(_closeText),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  };

  if ((await DeviceInfoPlugin().androidInfo).version.sdkInt >= 29) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        statusBarColor: Colors.transparent,
        systemStatusBarContrastEnforced: false,
      ),
    );
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }

  await Workmanager().initialize(callbackDispatcher);
  AppLogger.info('WorkManager initialised');

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appsProvider),
        ChangeNotifierProvider.value(value: settingsProvider),
        Provider.value(value: np),
        Provider<SourceProvider>.value(value: sourceProvider),
      ],
      child: EasyLocalization(
        supportedLocales: supportedLocales.map((e) => e.key).toList(),
        path: localeDir,
        fallbackLocale: fallbackLocale,
        useOnlyLangCode: false,
        useFallbackTranslations: true,
        child: const Obtainium(),
      ),
    ),
  );
}

class Obtainium extends StatefulWidget {
  const Obtainium({super.key});

  @override
  State<Obtainium> createState() => _ObtainiumState();
}

class _ObtainiumState extends State<Obtainium> {
  var _firstRunHandled = false;
  var _launchByNotifChecked = false;
  Locale? _lastLocale;
  SettingsProvider? _settingsProvider;
  int? _lastSyncedUpdateInterval;

  Future<void> _syncWorkManager() async {
    final settingsProvider = _settingsProvider;
    if (settingsProvider == null) return;
    final updateInterval = settingsProvider.updateInterval;
    _lastSyncedUpdateInterval = updateInterval;
    if (updateInterval <= 0) {
      // The user disabled background update checks: drop the periodic task so
      // the OS doesn't keep waking Obtainium for a check that would be skipped.
      await Workmanager().cancelByUniqueName(_workManagerTaskName);
    } else {
      await Workmanager().registerPeriodicTask(
        _workManagerTaskName,
        _workManagerTaskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: false,
          requiresDeviceIdle: false,
          requiresStorageNotLow: false,
        ),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      );
    }
  }

  void _onSettingsChanged() {
    final settingsProvider = _settingsProvider;
    if (settingsProvider != null &&
        settingsProvider.updateInterval != _lastSyncedUpdateInterval) {
      unawaited(_syncWorkManager());
    }
  }

  void _handleFirstRun(
    SettingsProvider settings,
    AppsProvider apps,
    BuildContext context,
  ) {
    if (_firstRunHandled) return;
    _firstRunHandled = true;
    // "All files access" so app data lives in public storage
    // (/storage/emulated/0/Obtainium) and survives reinstall. Requested on
    // every launch until granted (not just first run — upgrades of existing
    // installs need the prompt too). Opens the system settings page; if
    // denied, storage silently falls back to app-private dirs.
    if (!settings.isTV) {
      unawaited(() async {
        if (await Permission.manageExternalStorage.isGranted) return;
        await Permission.manageExternalStorage.request();
      }());
    }
    final isFirstRun = settings.checkAndFlipFirstRun();
    if (isFirstRun) {
      AppLogger.info('This is the first ever run of Obtainium.');
      if (!settings.isTV) {
        unawaited(Permission.notification.request());
      }
      if (!isFdroidBuild) {
        getInstalledInfo(obtainiumId)
            .then((value) {
              if (value?.versionName != null) {
                unawaited(
                  apps.saveApps([
                    App(
                      id: obtainiumId,
                      url: obtainiumUrl,
                      author: 'PT123123',
                      name: 'ObtainAPK',
                      installedVersion: value!.versionName,
                      latestVersion: value.versionName!,
                      apkUrls: [],
                      preferredApkIndex: 0,
                      additionalSettings: {
                        'versionDetection': true,
                        'apkFilterRegEx': 'fdroid',
                        'invertAPKFilter': true,
                      },
                      lastUpdateCheck: null,
                      pinned: false,
                    ),
                  ], onlyIfExists: false),
                );
              }
            })
            .catchError((err, stack) {
              AppLogger.error(
                err,
                stackTrace: stack,
                message: 'Failed to add ObtainAPK on first run',
              );
            });
      }
    }
    // One-time import of the bundled marketplace defaults
    // (marketplace/apps.json). Flag-based so it runs for fresh installs AND
    // upgrades of existing installs, but never re-adds apps the user
    // deleted afterwards.
    // NOTE: The grouped list (list.json) is now the source of truth for the
    // default apps and is pulled on EVERY startup via
    // _fetchGroupedListOnStartup(); marketplace/apps.json remains only as a
    // manually-importable file referenced by the README.
    if (settings.prefs?.getBool('marketplaceDefaultsImported') != true) {
      unawaited(settings.prefs?.setBool('marketplaceDefaultsImported', true));
    }
    final currentLang = context.locale.languageCode;
    final deviceLang = context.deviceLocale.languageCode;
    if (!supportedLocaleSet.contains(context.locale) ||
        (settings.forcedLocale == null && deviceLang != currentLang)) {
      settings.resetLocaleSafe(context);
    } else if (settings.forcedLocale != null) {
      context.setLocale(settings.forcedLocale!);
    }
  }

  /// Pulls the grouped app list (list.json) on every startup. Tries the remote
  /// URL first (with a mirror fallback), then falls back to the bundled
  /// [assets/list.json] so the groups are still available offline. The merged
  /// apps are tagged with their group id; existing user apps are never clobbered.
  Future<void> _fetchGroupedListOnStartup(AppsProvider appsProvider) async {
    final candidateUrls = <String>[
      defaultGroupedListUrl,
      'https://ghproxy.com/https://raw.githubusercontent.com/PT123123/obtainapk/main/list.json',
    ];
    String? raw;
    for (final u in candidateUrls) {
      try {
        final resp = await http
            .get(Uri.parse(u))
            .timeout(const Duration(seconds: 12));
        if (resp.statusCode >= 200 &&
            resp.statusCode < 300 &&
            resp.body.trim().isNotEmpty) {
          raw = resp.body;
          break;
        }
      } catch (e) {
        AppLogger.warn('Grouped list fetch failed for $u: $e');
      }
    }
    raw ??= await rootBundle
        .loadString('assets/list.json')
        .catchError((_) => '');
    if (raw.trim().isEmpty) {
      AppLogger.warn(
        'No grouped list available (remote + bundled fallback both failed).',
      );
      return;
    }
    try {
      await appsProvider.mergeGroupedList(raw);
      AppLogger.info('Merged grouped list into app store.');
    } catch (e, stack) {
      AppLogger.error(
        e,
        stackTrace: stack,
        message: 'mergeGroupedList failed',
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final settingsProvider = context.read<SettingsProvider>();
      await settingsProvider.initializeSettings();
      if (!mounted) return;
      _settingsProvider = settingsProvider;
      if (settingsProvider.isTV) {
        // TV remotes are the primary input, so focus highlights must always be
        // painted. The default automatic strategy can get stuck in "touch"
        // mode and leave the user with no visible focus position at all.
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
      }
      settingsProvider.addListener(_onSettingsChanged);
      final appsProvider = context.read<AppsProvider>();
      final notifs = context.read<NotificationsProvider>();

      unawaited(_syncWorkManager());
      _handleFirstRun(settingsProvider, appsProvider, context);
      unawaited(_fetchGroupedListOnStartup(appsProvider));

      if (!_launchByNotifChecked) {
        _launchByNotifChecked = true;
        unawaited(notifs.checkLaunchByNotif());
      }
    });
  }

  @override
  void dispose() {
    _settingsProvider?.removeListener(_onSettingsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = context.select<SettingsProvider, Color>(
      (p) => p.themeColor,
    );
    final colourSchemeMode = context.select<SettingsProvider, ColourSchemeMode>(
      (p) => p.colourSchemeMode,
    );
    final useBlackTheme = context.select<SettingsProvider, bool>(
      (p) => p.useBlackTheme,
    );
    final themeSetting = context.select<SettingsProvider, ThemeSettings>(
      (p) => p.theme,
    );
    final useSystemFont = context.select<SettingsProvider, bool>(
      (p) => p.useSystemFont,
    );
    final isTV = context.select<SettingsProvider, bool>((p) => p.isTV);

    return ObtainiumDynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        ColorScheme lightColorScheme;
        ColorScheme darkColorScheme;
        final schemeMode = colourSchemeMode;
        if (lightDynamic != null &&
            darkDynamic != null &&
            schemeMode == ColourSchemeMode.materialYou) {
          lightColorScheme = lightDynamic.harmonized();
          darkColorScheme = darkDynamic.harmonized();
        } else {
          final variant = switch (schemeMode) {
            ColourSchemeMode.vibrant => DynamicSchemeVariant.vibrant,
            ColourSchemeMode.expressive => DynamicSchemeVariant.expressive,
            _ => DynamicSchemeVariant.tonalSpot,
          };
          lightColorScheme = ColorScheme.fromSeed(
            seedColor: themeColor,
            dynamicSchemeVariant: variant,
          );
          darkColorScheme = ColorScheme.fromSeed(
            seedColor: themeColor,
            brightness: Brightness.dark,
            dynamicSchemeVariant: variant,
          );
        }

        if (useBlackTheme) {
          darkColorScheme = darkColorScheme.harmonized().copyWith(
            surface: Colors.black,
          );
        }

        if (useSystemFont) {
          unawaited(NativeFeatures.loadSystemFont());
        }

        return MaterialApp(
          title: 'obtainAPK',
          navigatorKey: appNavigatorKey,
          localizationsDelegates: [
            ...context.localizationDelegates,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          debugShowCheckedModeBanner: false,
          theme: buildObtainiumTheme(
            themeSetting == ThemeSettings.dark
                ? darkColorScheme
                : lightColorScheme,
            useSystemFont ? 'SystemFont' : 'Montserrat',
            isTV: isTV,
          ),
          darkTheme: buildObtainiumTheme(
            themeSetting == ThemeSettings.light
                ? lightColorScheme
                : darkColorScheme,
            useSystemFont ? 'SystemFont' : 'Montserrat',
            isTV: isTV,
          ),
          home: const HomePage(),
          builder: (context, child) {
            if (context.locale != _lastLocale) {
              _lastLocale = context.locale;
              setAppLocale(context.locale);
            }
            final content = Shortcuts(
              shortcuts: <LogicalKeySet, Intent>{
                LogicalKeySet(LogicalKeyboardKey.select):
                    const ActivateIntent(),
              },
              child: child ?? const SizedBox.shrink(),
            );
            // Geometric D-pad navigation, tuned for TV's two-pane layout and
            // remote-control usage. Left on the default reading-order policy
            // for touch devices.
            return isTV
                ? FocusTraversalGroup(
                    policy: WidgetOrderTraversalPolicy(),
                    child: content,
                  )
                : content;
          },
        );
      },
    );
  }
}
