import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_package_manager/android_package_manager.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/utils/color_utils.dart';
import 'package:obtainium/providers/app_json_migration.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:path_provider/path_provider.dart';

/// App persistence (load/save/remove), icons, and version-detection helpers.
const _corruptFileSuffix = '.corrupt';

/// Makes temporary save files unique even when concurrent [saveApps] calls
/// target the same app.
int _saveTempCounter = 0;

/// Whether a cached app icon can be reused instead of re-reading it from the
/// platform.
///
/// An app's icon is packaged in its APK, so it can only change when the app is
/// updated. The cache is therefore only stale when the installed package's
/// [PackageInfo.lastUpdateTime] is newer than the cache file (or when
/// [ignoreCache] forces a refresh), keeping the relatively expensive
/// `getAppIcon` platform call off the hot path.
bool isIconCacheUsable({
  required bool cacheExists,
  required DateTime? cacheModified,
  int? packageLastUpdateTime,
  bool ignoreCache = false,
}) {
  if (ignoreCache || !cacheExists) {
    return false;
  }
  if (packageLastUpdateTime == null || cacheModified == null) {
    return true;
  }
  return cacheModified.millisecondsSinceEpoch >= packageLastUpdateTime;
}

extension AppsProviderLifecycle on AppsProvider {
  bool _getNaiveStandardVersionDetection(App app, {AppSource? source}) {
    AppSource resolved;
    if (source != null) {
      resolved = source;
    } else {
      try {
        resolved = SourceProvider().getSource(
          app.url,
          overrideSource: app.overrideSource,
        );
      } catch (_) {
        return false;
      }
    }
    return app.settings.getBool('naiveStandardVersionDetection') ||
        resolved.naiveStandardVersionDetection;
  }

  Future<Directory> getAppsDir() async {
    final cached = cachedAppsDir;
    if (cached != null && cached.existsSync()) return cached;
    // The cached directory can disappear at runtime (external storage
    // remounted after a system update, storage cleanup). Drop the stale
    // reference and re-create it instead of renaming into a missing path.
    cachedAppsDir = null;
    final Directory appsDir = Directory(
      '${(await getAppStorageDir()).path}/app_data',
    );
    try {
      if (!appsDir.existsSync()) {
        appsDir.createSync(recursive: true);
      }
    } catch (_) {
      final fallbackDir = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/app_data',
      );
      if (!fallbackDir.existsSync()) {
        fallbackDir.createSync(recursive: true);
      }
      return cachedAppsDir = fallbackDir;
    }
    return cachedAppsDir = appsDir;
  }

  /// Private mirror of the app JSON files (inside app-scoped storage). If the
  /// active apps directory IS this mirror, returns null (nothing to mirror).
  Future<Directory?> appsMirrorDir(Directory active) async {
    try {
      final mirror = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/app_data',
      );
      if (mirror.path == active.path) return null;
      if (!mirror.existsSync()) mirror.createSync(recursive: true);
      return mirror;
    } catch (_) {
      return null;
    }
  }

  /// If the active app_data directory contains no app JSON files but another
  /// known location does (public/private fallback flips, a failed one-shot
  /// migration, or external cleanup of the public folder), copy the apps
  /// over so the user's list is not lost. No-op when the dir is populated.
  Future<void> _healAppsDir(Directory active) async {
    try {
      final hasApps = active
          .listSync()
          .whereType<File>()
          .any((f) => f.path.toLowerCase().endsWith('.json'));
      if (hasApps) return;
      final candidates = <Directory>[];
      if (Platform.isAndroid) {
        try {
          final ext = await getExternalStorageDirectory();
          if (ext != null) candidates.add(Directory('${ext.path}/app_data'));
        } catch (_) {}
      }
      final mirror = await appsMirrorDir(active);
      if (mirror != null) candidates.add(mirror);
      final public = Directory('/storage/emulated/0/Obtainium/app_data');
      if (public.path != active.path) candidates.add(public);
      for (final cand in candidates) {
        if (cand.path == active.path || !cand.existsSync()) continue;
        final jsons = cand
            .listSync()
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.json'))
            .toList();
        if (jsons.isEmpty) continue;
        if (!active.existsSync()) active.createSync(recursive: true);
        for (final f in jsons) {
          await f.copy('${active.path}/${f.uri.pathSegments.last}');
        }
        AppLogger.info(
          'Healed empty apps dir from ${cand.path} (${jsons.length} apps).',
        );
        break;
      }
    } catch (e) {
      AppLogger.warn('Apps dir heal failed: ${e.toString()}');
    }
  }

  /// Writes [app]'s JSON file, re-resolving the apps directory and retrying
  /// once if the filesystem reports a missing path. Without the retry, a
  /// directory that vanished between the existence check and the rename makes
  /// saves/imports fail with a user-visible PathNotFoundException. See #2860.
  Future<void> _writeAppJson(App app) async {
    Future<void> attempt() async {
      final String filePath = '${(await getAppsDir()).path}/${app.id}.json';
      // Unique temp path: two concurrent saves of the same app must not
      // interleave writes or race each other's rename. #2089
      final String tmpPath =
          '$filePath.${DateTime.now().microsecondsSinceEpoch}-${_saveTempCounter++}.tmp';
      final String json = jsonEncode(app.toJson());
      await File(tmpPath).writeAsString(json);
      await File(tmpPath).rename(filePath);
      // Keep the private mirror in sync so the app list survives the active
      // directory being wiped externally (system cleanup, permission
      // fallback flips). Best-effort; never fail the real save for it.
      try {
        final active = await getAppsDir();
        final mirror = await appsMirrorDir(active);
        if (mirror != null) {
          await File('${mirror.path}/${app.id}.json').writeAsString(json);
        }
      } catch (_) {}
    }

    try {
      await attempt();
    } on FileSystemException {
      cachedAppsDir = null;
      await attempt();
    }
  }

  bool isVersionDetectionPossible(AppInMemory? app) {
    if (app?.app == null) {
      return false;
    }
    AppSource source;
    try {
      source = SourceProvider().getSource(
        app!.app.url,
        overrideSource: app.app.overrideSource,
      );
    } catch (_) {
      // Source temporarily unresolvable — conservatively assume version
      // detection is not possible so the update badge stays visible.
      return false;
    }
    final bool isHTMLWithNoVersionDetection =
        (source is HTML &&
        app.app.settings
                .getStringOrNull('versionExtractionRegEx')
                ?.isNotEmpty !=
            true);
    return versionDetectionPossible(
      trackOnly: app.app.settings.getBool('trackOnly'),
      releaseDateAsVersion: app.app.settings.getBool('releaseDateAsVersion'),
      isHtmlWithNoVersionDetection: isHTMLWithNoVersionDetection,
      versionDetectionDisallowed: source.versionDetectionDisallowed,
      realInstalledVersion: realInstalledVersionOf(app.app, app.installedInfo),
      trackedVersion: app.app.installedVersion,
      latestVersion: app.app.latestVersion,
      naiveStandardVersionDetection: _getNaiveStandardVersionDetection(
        app.app,
        source: source,
      ),
    );
  }

  /// Reconciles reported vs. real installed/latest versions for [app].
  /// Returns the modified app if any corrections were made, or null.
  App? reconcileInstallStatus(App app, PackageInfo? installedInfo) {
    var modded = false;
    final trackOnly = app.settings.getBool('trackOnly');
    final versionDetectionIsStandard = app.settings.getBool('versionDetection');
    final naiveStandardVersionDetection = _getNaiveStandardVersionDetection(
      app,
    );
    final String? realInstalledVersion = realInstalledVersionOf(
      app,
      installedInfo,
    );
    // 1. Compare reported vs. real installed versions where one is null.
    if (installedInfo == null && app.installedVersion != null && !trackOnly) {
      app = app.copyWith(installedVersion: null);
      modded = true;
    } else if (realInstalledVersion != null && app.installedVersion == null) {
      app = app.copyWith(installedVersion: realInstalledVersion);
      modded = true;
    }
    // 1.5-3. Collapse purely cosmetic version-format differences and reconcile
    // the reported version against the real on-device and latest versions.
    final correctedInstalledVersion = reconcileTrackedVersion(
      trackedVersion: app.installedVersion,
      realInstalledVersion: realInstalledVersion,
      latestVersion: app.latestVersion,
      versionDetectionIsStandard: versionDetectionIsStandard,
      naiveStandardVersionDetection: naiveStandardVersionDetection,
      installedVersionCode: installedInfo?.versionCode,
    );
    if (correctedInstalledVersion != null &&
        correctedInstalledVersion != app.installedVersion) {
      app = app.copyWith(installedVersion: correctedInstalledVersion);
      modded = true;
    }
    // 4. Disable version detection if versions are not standardizable.
    if (installedInfo != null &&
        versionDetectionIsStandard &&
        !isVersionDetectionPossible(
          AppInMemory(app, null, installedInfo, null),
        )) {
      app = app.copyWith(
        additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
          ..['versionDetection'] = false,
      );
      AppLogger.info('Could not reconcile version formats for: ${app.id}');
      modded = true;
    }

    return modded ? app : null;
  }

  Future<void> loadApps({String? singleId}) async {
    await waitForAppsToLoad();
    appsLoadingCompleter = Completer<void>();
    loadingApps = true;
    notify();
    try {
      final sp = SourceProvider();
      final List<List<String>> errors = [];
      final installedAppsData = await getAllInstalledInfo();
      final Map<String, PackageInfo> installedAppsMap = {
        for (var i in installedAppsData)
          if (i.packageName != null) i.packageName!: i,
      };
      final List<String> removedAppIds = [];
      final List<App> correctedApps = [];
      // Shared across the concurrent per-app iterations below: the label map is
      // built at most once per load, and `claimed` keeps two tracked apps from
      // resolving to the same installed package.
      final Set<String> claimedInstalledPackages = {};
      Future<Map<String, String>>? installedLabelsFuture;
      Future<Map<String, String>> installedLabels() =>
          installedLabelsFuture ??= getInstalledPackageLabels(installedAppsData);
      // TODO: Replace listSync() with async list().toList()
      final activeAppsDir = await getAppsDir();
      await _healAppsDir(activeAppsDir);
      await Future.wait(
        activeAppsDir // Parse Apps from JSON
            .listSync()
            .map((item) async {
              App? app;
              if (item.path.toLowerCase().endsWith('.json') &&
                  (singleId == null ||
                      item.path.split('/').last.toLowerCase() ==
                          '${singleId.toLowerCase()}.json')) {
                try {
                  app = appFromStoredJson(
                    jsonDecode(await File(item.path).readAsString()),
                  );
                } catch (err) {
                  if (err is FormatException) {
                    // Genuinely corrupt JSON: set it aside so it stops failing.
                    AppLogger.error(
                      err,
                      message: 'Corrupt JSON, renaming ${item.path}',
                    );
                    unawaited(item.rename('${item.path}$_corruptFileSuffix'));
                  } else {
                    // Other errors (e.g. a temporarily unresolvable source):
                    // skip but keep the file so it can load once resolved.
                    AppLogger.warn(
                      'Error loading app ${item.path} (skipped, file kept): $err',
                    );
                  }
                }
              }
              if (app != null) {
                apps.update(
                  app.id,
                  (value) => value.copyWith(app: app!),
                  ifAbsent: () => AppInMemory(app!, null, null, null),
                );
                // Resolve source type separately — a failure here should
                // never prevent install-status reconciliation or cause the
                // app to be removed (it could be a transient network issue
                // or a URL that temporarily doesn't resolve).
                String? sourceType;
                try {
                  final src = sp.getSource(
                    app.url,
                    overrideSource: app.overrideSource,
                  );
                  sourceType = src.sourceIdentifier;
                } catch (e) {
                  AppLogger.info(
                    'Could not resolve source for ${app.id} during load: $e',
                  );
                }
                try {
                  // If the app is installed, grab its OS data and reconcile install statuses
                  PackageInfo? installedInfo = installedAppsMap[app.id];
                  String? learnedLabel;
                  var learnedCache = false;
                  if (installedInfo != null) {
                    claimedInstalledPackages.add(app.id);
                  } else if (!app.settings.getBool('trackOnly')) {
                    // The tracked ID matched nothing installed (an
                    // inferred/placeholder ID, or a differing applicationId).
                    // 1. Fall back to the real package name learned earlier.
                    final cachedPackageName = app.cachedInstalledPackageName;
                    final cachedInfo =
                        cachedPackageName != null &&
                            !claimedInstalledPackages.contains(cachedPackageName)
                        ? installedAppsMap[cachedPackageName]
                        : null;
                    if (cachedInfo != null) {
                      installedInfo = cachedInfo;
                      claimedInstalledPackages.add(cachedPackageName!);
                      AppLogger.info(
                        'Matched ${app.id} to installed package '
                        '$cachedPackageName (cached)',
                      );
                    } else {
                      // 2. Match by app name instead, so an actually installed
                      // app is not reported as "not installed" (which also left
                      // it without an icon).
                      final labels = await installedLabels();
                      final matched = matchInstalledAppByName(
                        app,
                        installedAppsData,
                        labels,
                        claimedInstalledPackages,
                      );
                      if (matched?.packageName != null) {
                        installedInfo = matched;
                        learnedLabel = labels[matched!.packageName!];
                        claimedInstalledPackages.add(matched.packageName!);
                        AppLogger.info(
                          'Matched ${app.id} to installed package '
                          '${matched.packageName} by name',
                        );
                      }
                    }
                  }
                  // Remember the real package name / label so later loads — and
                  // Obtainium updating itself, which wipes the in-memory caches
                  // — still detect the app as installed even when its tracked
                  // name is unusable.
                  final realPackageName = installedInfo?.packageName;
                  if (realPackageName != null) {
                    final newSettings = Map<String, dynamic>.from(
                      app.additionalSettings,
                    );
                    if (app.cachedInstalledPackageName != realPackageName) {
                      newSettings['installedPackageName'] = realPackageName;
                      learnedCache = true;
                    }
                    if (app.cachedAppLabel == null) {
                      // A blank tracked name makes the app unidentifiable in
                      // the list; learn the label from the installed package.
                      if (learnedLabel == null && app.name.trim().isEmpty) {
                        learnedLabel = await getInstalledPackageLabel(
                          realPackageName,
                        );
                      }
                      if (learnedLabel != null) {
                        newSettings['appLabel'] = learnedLabel;
                        learnedCache = true;
                      }
                    }
                    if (learnedCache) {
                      app = app.copyWith(additionalSettings: newSettings);
                    }
                  }
                  // Reconcile differences between the installed and recorded install info
                  final moddedApp = reconcileInstallStatus(app, installedInfo);
                  if (moddedApp != null) {
                    app = moddedApp;
                    correctedApps.add(app);
                    // Note the app ID if it was uninstalled externally
                    if (moddedApp.installedVersion == null) {
                      removedAppIds.add(moddedApp.id);
                    }
                  } else if (learnedCache) {
                    // Nothing else changed, but the learned cache still needs
                    // to reach disk.
                    correctedApps.add(app);
                  }
                  // Update the app in memory with install info and corrections
                  apps.update(
                    app.id,
                    (value) => value.copyWith(
                      app: app!,
                      installedInfo: installedInfo,
                      sourceType: sourceType ?? value.sourceType,
                    ),
                    ifAbsent: () => AppInMemory(
                      app!,
                      null,
                      installedInfo,
                      null,
                      sourceType: sourceType,
                    ),
                  );
                } catch (e) {
                  if (e is RateLimitError || e is SocketException) {
                    AppLogger.info(
                      'Transient error loading app ${app!.id}, will retry: $e',
                    );
                  } else {
                    errors.add([app!.id, app.finalName, e.toString()]);
                  }
                }
              }
            }),
      );
      if (errors.isNotEmpty) {
        for (var error in errors) {
          AppLogger.error(
            error[2],
            message: 'Removing app ${error[0]} (${error[1]}) due to load error',
          );
        }
        unawaited(removeApps(errors.map((e) => e[0]).toList()));
        unawaited(
          NotificationsProvider().notify(
            AppsRemovedNotification(errors.map((e) => [e[1], e[2]]).toList()),
          ),
        );
      }
      // Delete externally uninstalled Apps if needed
      if (removedAppIds.isNotEmpty &&
          settingsProvider.removeOnExternalUninstall) {
        await removeApps(removedAppIds);
      }
      if (correctedApps.isNotEmpty) {
        await saveApps(
          correctedApps,
          attemptToCorrectInstallStatus: false,
          reuseInstalledInfo: true,
        );
      }
    } finally {
      loadingApps = false;
      appsLoadingCompleter?.complete();
      appsLoadingCompleter = null;
      notify();
    }
    if (!isBg && apps.isNotEmpty) {
      unawaited(
        Future(() async {
          for (final entry in apps.entries.toList()) {
            await updateAppIcon(entry.key);
            await Future<void>.delayed(Duration.zero);
          }
          notify();
        }),
      );
    }
  }

  Future<void> updateAppIcon(String? appId, {bool ignoreCache = false}) async {
    final app = apps[appId];
    final cachedIcon = File('${iconsCacheDir.path}/$appId.png');
    final cacheExists = cachedIcon.existsSync();
    final alreadyCached = isIconCacheUsable(
      ignoreCache: ignoreCache,
      cacheExists: cacheExists,
      cacheModified: cacheExists ? cachedIcon.lastModifiedSync() : null,
      packageLastUpdateTime: app?.installedInfo?.lastUpdateTime,
    );
    if (app?.icon == null || !alreadyCached) {
      final icon = alreadyCached
          ? (await cachedIcon.readAsBytes())
          : (await app?.installedInfo?.applicationInfo?.getAppIcon());
      if (icon != null && !alreadyCached) {
        unawaited(cachedIcon.writeAsBytes(icon));
      }
      if (icon != null) {
        apps.update(
          apps[appId]!.app.id,
          (value) => value.copyWith(icon: icon),
          ifAbsent: () => AppInMemory(
            apps[appId]!.app,
            null,
            apps[appId]?.installedInfo,
            icon,
          ),
        );
      }
    }
  }

  /// Persists a list of [App] objects to disk as JSON files and updates in-memory state.
  ///
  /// When [reuseInstalledInfo] is true, the already-loaded [PackageInfo]/icon
  /// for each app are reused instead of re-querying the platform and
  /// re-decoding icons. This avoids expensive per-app platform-channel calls
  /// and icon decoding on the UI isolate during bulk operations like update
  /// checks, where installed info and icons don't change.
  Future<void> saveApps(
    List<App> apps, {
    bool attemptToCorrectInstallStatus = true,
    bool onlyIfExists = true,
    bool reuseInstalledInfo = false,
  }) async {
    await Future.wait(
      apps.map((a) async {
        var app = a.copyWith();
        final bool canReuse =
            reuseInstalledInfo && this.apps.containsKey(app.id);
        final PackageInfo? info = canReuse
            ? this.apps[app.id]!.installedInfo
            : await getInstalledInfo(app.id);
        final Uint8List? icon = canReuse
            ? this.apps[app.id]!.icon
            : await info?.applicationInfo?.getAppIcon();
        if (!canReuse) {
          app = app.copyWith(
            name: await (info?.applicationInfo?.getAppLabel()) ?? app.name,
          );
        }
        if (attemptToCorrectInstallStatus) {
          app = reconcileInstallStatus(app, info) ?? app;
        }
        if (!onlyIfExists || this.apps.containsKey(app.id)) {
          await _writeAppJson(app);
        }
        if (this.apps.containsKey(app.id)) {
          this.apps[app.id] = this.apps[app.id]!.copyWith(
            app: app,
            installedInfo: info,
            icon: icon,
          );
        } else if (!onlyIfExists) {
          this.apps[app.id] = AppInMemory(app, null, info, icon);
        }
        if (info == null) {
          final cachedIcon = File('${iconsCacheDir.path}/${app.id}.png');
          if (cachedIcon.existsSync()) cachedIcon.deleteSync();
        } else if (!canReuse && icon != null) {
          // Persist the freshly fetched icon so future cold starts can reuse
          // it (and so a changed icon replaces the stale cached one).
          await File('${iconsCacheDir.path}/${app.id}.png').writeAsBytes(icon);
        }
      }),
    );
    notify();
    scheduleAutoExport();
  }

  /// Deletes app JSON files, cached APKs, and icons for the given app IDs, then updates state.
  Future<void> removeApps(List<String> appIds) async {
    final apkFiles = await apkDir.list().toList();
    await Future.wait(
      appIds.map((appId) async {
        final activeDir = await getAppsDir();
        final File file = File('${activeDir.path}/$appId.json');
        if (file.existsSync()) {
          deleteFile(file);
        }
        // Also drop the mirror copy so a heal can't resurrect removed apps.
        try {
          final mirror = await appsMirrorDir(activeDir);
          if (mirror != null) {
            final mf = File('${mirror.path}/$appId.json');
            if (mf.existsSync()) mf.deleteSync();
          }
        } catch (_) {}
        await Future.wait(
          apkFiles
              .where(
                (element) => element.path.split('/').last.startsWith('$appId-'),
              )
              .map((element) => element.delete(recursive: true)),
        );
        final cachedIcon = File('${iconsCacheDir.path}/$appId.png');
        if (cachedIcon.existsSync()) cachedIcon.deleteSync();
        if (apps.containsKey(appId)) {
          apps.remove(appId);
        }
      }),
    );
    if (appIds.isNotEmpty) {
      notify();
      scheduleAutoExport();
    }
  }

  Future<bool> removeAppsWithModal(BuildContext context, List<App> apps) async {
    final showUninstallOption = apps
        .where(
          (a) => a.installedVersion != null && !a.settings.getBool('trackOnly'),
        )
        .isNotEmpty;
    final values = await showDialog(
      context: context,
      builder: (BuildContext ctx) {
        return GeneratedFormModal(
          primaryActionColour: Theme.of(context).colorScheme.error,
          title: plural('removeAppQuestion', apps.length),
          items: !showUninstallOption
              ? []
              : [
                  [
                    GeneratedFormSwitch(
                      'rmAppEntry',
                      label: tr('removeFromObtainium'),
                      value: true,
                    ),
                  ],
                  [
                    GeneratedFormSwitch(
                      'uninstallApp',
                      label: tr('uninstallFromDevice'),
                    ),
                  ],
                ],
          initValid: true,
        );
      },
    );
    if (values != null) {
      final bool uninstall =
          values['uninstallApp'] == true && showUninstallOption;
      final bool remove = values['rmAppEntry'] == true || !showUninstallOption;
      if (uninstall) {
        for (var i = 0; i < apps.length; i++) {
          if (apps[i].installedVersion != null) {
            await uninstallApp(apps[i].id);
            apps[i] = apps[i].copyWith(installedVersion: null);
          }
        }
        await saveApps(apps, attemptToCorrectInstallStatus: false);
      }
      if (remove) {
        await removeApps(apps.map((e) => e.id).toList());
      }
      return remove;
    }
    return false;
  }

  Future<void> openAppSettings(String appId) async {
    final AndroidIntent intent = AndroidIntent(
      action: 'action_application_details_settings',
      data: 'package:$appId',
    );
    await intent.launch();
  }

  void addMissingCategories(SettingsProvider settingsProvider) {
    final cats = Map<String, int>.from(settingsProvider.categories);
    apps.forEach((key, value) {
      for (var c in value.app.categories) {
        if (!cats.containsKey(c)) {
          cats[c] = generateRandomLightColor().toARGB32();
        }
      }
    });
    settingsProvider.setCategories(cats, appsProvider: this);
  }
}
