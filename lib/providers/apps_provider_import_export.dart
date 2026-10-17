import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/core/logging/app_logger.dart';

import 'package:obtainium/providers/app_json_migration.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:shared_storage/shared_storage.dart' as saf;

/// Import/export of app configurations for [AppsProvider].
extension AppsProviderImportExport on AppsProvider {
  /// Builds an exportable JSON map containing app data and optionally settings.
  Map<String, dynamic> generateExportJSON({
    List<String>? appIds,
    int? overrideExportSettings,
  }) {
    int shouldExportSettings = settingsProvider.exportSettings;
    if (overrideExportSettings != null) {
      shouldExportSettings = overrideExportSettings;
    }
    final appList = apps.values
        .where((e) => appIds == null || appIds.contains(e.app.id))
        .where(
          (e) =>
              !settingsProvider.exportInstalledOnly ||
              e.app.installedVersion != null,
        )
        .map((e) {
          final json = e.app.toJson();
          if (shouldExportSettings < 2) {
            // Per-app credentials (e.g. github-creds) live inside
            // additionalSettings, not prefs, so they must be stripped here
            // too when the export is not meant to include secrets.
            final additionalSettings =
                jsonDecode(json['additionalSettings'] as String)
                    as Map<String, dynamic>;
            additionalSettings.removeWhere((key, _) => key.endsWith('-creds'));
            json['additionalSettings'] = jsonEncode(additionalSettings);
          }
          return json;
        })
        .toList();
    Map<String, dynamic>? settingsMap;
    if (shouldExportSettings > 0) {
      final settingsValueKeys = settingsProvider.prefs?.getKeys().toSet();
      if (shouldExportSettings < 2) {
        settingsValueKeys?.removeWhere((k) => k.endsWith('-creds'));
      }
      settingsMap = Map<String, Object?>.fromEntries(
        (settingsValueKeys
                ?.map((key) => MapEntry(key, settingsProvider.prefs?.get(key)))
                .toList()) ??
            [],
      );
    }
    final schema = ExportSchema(
      schemaVersion: currentExportSchemaVersion,
      exportedAt: DateTime.now().toIso8601String(),
      appVersion: kPackageVersion,
      apps: appList,
      settings: settingsMap,
    );
    return schema.toJson();
  }

  /// Returns the app IDs contained in an import payload without applying it.
  ///
  /// Supports the current schema (`{schemaVersion, apps: [...]}`), the legacy
  /// `{apps: [...]}` wrapper and the older bare list format. Throws if the
  /// payload isn't decodable JSON, mirroring [import].
  List<String> appIdsInImportJSON(String appsJSON) {
    final decoded = jsonDecode(appsJSON);
    final List<dynamic> appMaps;
    if (decoded is Map) {
      appMaps = (decoded['apps'] as List<dynamic>?) ?? const [];
    } else if (decoded is List) {
      appMaps = decoded;
    } else {
      return const [];
    }
    return appMaps
        .whereType<Map>()
        .map((e) => e['id'])
        .whereType<String>()
        .toList();
  }

  /// Exports all app data (and optionally settings) as a JSON file to the configured export directory.
  Future<String?> export({
    bool pickOnly = false,
    isAuto = false,
    SettingsProvider? sp,
  }) async {
    final SettingsProvider settingsProvider = sp ?? this.settingsProvider;
    final customName = settingsProvider.autoExportFileName;
    final hasCustomName = customName != null && customName.isNotEmpty;
    var exportDir = await settingsProvider.getExportDir();
    if (isAuto) {
      if (!settingsProvider.autoExportOnChanges) {
        return null;
      }
      if (exportDir == null) {
        if (settingsProvider.prefs?.getString('exportDir') != null) {
          AppLogger.info(
            'Auto-export skipped: export directory permission unavailable',
          );
        }
        return null;
      }
      final files = await saf
          .listFiles(exportDir, columns: [saf.DocumentFileColumn.id])
          .where((f) {
            final name = f.uri.pathSegments.last;
            return name.endsWith('-auto.json') ||
                (hasCustomName && name == '$customName.json');
          })
          .toList();
      if (files.isNotEmpty) {
        for (final f in files) {
          // Await so the old files are gone before the replacement is created;
          // an unawaited delete could race the new file (same custom name) and
          // an export failure would otherwise already have lost the backup.
          await saf.delete(f.uri);
        }
      }
    }
    if (exportDir == null || pickOnly) {
      await settingsProvider.pickExportDir();
      exportDir = await settingsProvider.getExportDir();
    }
    if (exportDir == null) {
      return null;
    }
    String? returnPath;
    if (!pickOnly) {
      const encoder = JsonEncoder.withIndent('    ');
      final Map<String, dynamic> finalExport = generateExportJSON();
      // In auto mode a custom name gives a fixed file that's overwritten each
      // time, instead of a new timestamped file per change.
      final displayName = (isAuto && hasCustomName)
          ? '$customName.json'
          : '${tr('obtainiumExportHyphenatedLowercase')}-${DateTime.now().toIso8601String().replaceAll(':', '-')}${isAuto ? '-auto' : ''}.json';
      final result = await saf.createFile(
        exportDir,
        displayName: displayName,
        mimeType: 'application/json',
        bytes: Uint8List.fromList(utf8.encode(encoder.convert(finalExport))),
      );
      if (result == null) {
        throw ObtainiumError(tr('unexpectedError'));
      }
      returnPath = exportDir.pathSegments
          .join('/')
          .replaceFirst(RegExp(r'^tree/[^:]+:'), '/');
    }
    return returnPath;
  }

  /// Imports apps (and optionally settings) from a JSON string, returning the parsed apps and a settings-present flag.
  Future<MapEntry<List<App>, bool>> import(String appsJSON) async {
    dynamic decodedJSON;
    try {
      decodedJSON = jsonDecode(appsJSON);
    } catch (e) {
      throw ObtainiumError('${tr('failedToImport')}: ${e.toString()}');
    }
    final hasSchemaVersion =
        decodedJSON is Map && decodedJSON.containsKey('schemaVersion');
    List<App> importedApps;
    ExportSchema? schema;
    try {
      if (hasSchemaVersion) {
        schema = ExportSchema.fromJson(decodedJSON as Map<String, dynamic>);
        importedApps = schema.apps.map(appFromStoredJson).toList();
      } else {
        final newFormat = decodedJSON is! List;
        importedApps =
            ((newFormat ? decodedJSON['apps'] : decodedJSON) as List<dynamic>)
                .map((e) => appFromStoredJson(e))
                .toList();
      }
    } catch (e) {
      throw ObtainiumError('${tr('failedToImport')}: ${e.toString()}');
    }
    await waitForAppsToLoad();
    for (var i = 0; i < importedApps.length; i++) {
      final a = importedApps[i];
      final installedInfo = await getInstalledInfo(a.id);
      importedApps[i] = a.copyWith(
        installedVersion: realInstalledVersionOf(a, installedInfo),
      );
    }
    await saveApps(importedApps, onlyIfExists: false);
    bool hasSettings = false;
    if (hasSchemaVersion && schema != null) {
      if (schema.settings != null) {
        hasSettings = true;
        _applyImportedSettings(schema.settings!);
      }
    } else if (decodedJSON is! List && decodedJSON['settings'] != null) {
      hasSettings = true;
      _applyImportedSettings(decodedJSON['settings'] as Map<String, Object?>);
    }
    return MapEntry<List<App>, bool>(importedApps, hasSettings);
  }

  /// Merges a grouped list (list.json format: `{groups:[{id,name,apps:[]}]}`)
  /// into the store. Each app is tagged with its group id in [App.groups].
  /// Existing apps keep all their other data (pinned, installedVersion,
  /// additionalSettings, …) — only the group tags are unioned in. New apps are
  /// added. Safe to call repeatedly: it is idempotent.
  ///
  /// Apps the user removed from a grouped list stay removed: their URL is in
  /// [SettingsProvider.groupedListSuppressed] and is skipped instead of re-added.
  /// A tombstone for a URL that is tracked again (manually re-added) is dropped.
  ///
  /// Existing apps are matched by ID first, then by URL: a list entry whose
  /// placeholder ID was replaced by the real package name on install (or a
  /// manually re-added URL) must not be added a second time. As a repair for
  /// lists duplicated by earlier builds, same-URL placeholder entries that
  /// shadow a real-ID entry are removed before merging.
  ///
  /// Group metadata (`{id,name}`) is persisted to settings so the group
  /// switcher can render its chips without re-fetching.
  Future<({int added, int updated, int suppressed})> mergeGroupedList(
    String raw,
  ) async {
    // Merging reads the whole store, so it must not race [loadApps] or every
    // existing app would look missing and get re-added.
    await waitForAppsToLoad();
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      throw ObtainiumError('${tr('failedToImport')}: ${e.toString()}');
    }
    if (decoded is! Map) {
      throw ObtainiumError(tr('failedToImport'));
    }
    final groups = decoded['groups'] as List<dynamic>? ?? [];

    // First pass: group ids are needed before the apps are merged, because
    // older builds stored the group tag inside [App.categories] and that
    // legacy tag has to be recognised (and moved out) for every app.
    final List<Map<String, String>> groupMeta = [];
    final Set<String> groupIds = <String>{};
    for (final g in groups) {
      if (g is! Map) continue;
      final gid = g['id'] as String?;
      if (gid == null || gid.isEmpty) continue;
      groupIds.add(gid);
      groupMeta.add({'id': gid, 'name': (g['name'] as String?) ?? gid});
    }

    // Second pass: collect every app and the full set of groups it belongs to.
    // An app listed in more than one group must end up with all of its tags
    // (collecting into a set avoids the last group silently winning).
    final Map<String, App> parsedApps = {};
    final Map<String, Set<String>> tagsByAppId = {};
    for (final g in groups) {
      if (g is! Map) continue;
      final gid = g['id'] as String?;
      if (gid == null || gid.isEmpty) continue;
      final appsList = g['apps'] as List<dynamic>? ?? [];
      for (final a in appsList) {
        if (a is! Map) continue;
        App parsed;
        try {
          parsed = appFromStoredJson(Map<String, dynamic>.from(a));
        } catch (e) {
          AppLogger.warn('Skipping unparseable app in group $gid: $e');
          continue;
        }
        parsedApps.putIfAbsent(parsed.id, () => parsed);
        tagsByAppId.putIfAbsent(parsed.id, () => <String>{}).add(gid);
      }
    }

    // Repair pass for lists duplicated by earlier builds: a placeholder-ID
    // app whose URL is already tracked (typically under the real package name
    // the ID was renamed to on install) shows the same app twice. Keep the
    // real-ID entry — or, when every entry for the URL is still a placeholder,
    // the first one — and drop the rest. Same-URL entries with two distinct
    // real package IDs are legitimate (one repo, two packages) and untouched.
    final List<String> duplicateIdsToRemove = [];
    final Map<String, String> carriedInstalledPackage = {};
    {
      final idsByUrl = <String, List<String>>{};
      apps.forEach((id, e) {
        idsByUrl.putIfAbsent(e.app.url, () => []).add(id);
      });
      idsByUrl.forEach((url, ids) {
        final (keeperId, removeIds) = resolveSameUrlDuplicates(
          ids,
          (id) => isTempId(apps[id]!.app),
        );
        for (final id in removeIds) {
          final dup = apps[id]!.app;
          final dupPackage = dup.cachedInstalledPackageName;
          if (dupPackage != null &&
              apps[keeperId]!.app.cachedInstalledPackageName == null) {
            carriedInstalledPackage[keeperId] = dupPackage;
          }
          duplicateIdsToRemove.add(id);
          AppLogger.info(
            'Removing duplicate tracked app $id (same URL as $keeperId): $url',
          );
        }
      });
    }
    if (duplicateIdsToRemove.isNotEmpty) {
      await removeApps(duplicateIdsToRemove);
    }

    final List<App> toSave = [];
    // Index the surviving store by URL so the ID lookup below can fall back
    // for list entries whose stored ID differs from the one in list.json.
    final existingByUrl = <String, App>{};
    apps.forEach((_, e) {
      existingByUrl.putIfAbsent(e.app.url, () => e.app);
    });
    // Apps the user deleted from a grouped list must not come back with the next
    // sync; they are skipped until restored in Settings.
    final previouslySuppressed = settingsProvider.groupedListSuppressed;
    final suppressedUrls = resolveListSuppression(
      suppressed: previouslySuppressed,
      trackedUrls: existingByUrl.keys.toSet(),
    ).toSet();
    if (suppressedUrls.length != previouslySuppressed.length) {
      final revived = previouslySuppressed.where(
        (u) => !suppressedUrls.contains(u),
      );
      settingsProvider.groupedListSuppressed = suppressedUrls.toList();
      AppLogger.info(
        'Cleared list removals for re-tracked apps: ${revived.join(', ')}',
      );
    }
    final List<({App stored, App adopted})> adoptions = [];
    var added = 0;
    var updated = 0;
    var suppressed = 0;
    parsedApps.forEach((id, parsed) {
      final tags = tagsByAppId[id]!.toList();
      final existing = apps[id]?.app ?? existingByUrl[parsed.url];
      if (existing == null && suppressedUrls.contains(parsed.url)) {
        suppressed++;
        return;
      }
      if (existing != null &&
          shouldAdoptListAppId(
            storedId: existing.id,
            listId: id,
            storedInstalled: apps[existing.id]?.installedInfo != null,
            listIdAlreadyTracked: apps.containsKey(id),
          )) {
        adoptions.add((
          stored: existing,
          adopted: existing.copyWith(
            id: id,
            // The list owns this entry's display metadata, so take the name the
            // repo now ships under; the user's own settings are kept.
            name: parsed.name,
            author: parsed.author,
            groups: {...existing.groups, ...tags}.toList(),
            // The package/label learned under the old ID belong to the old
            // package - dropping them lets the next load re-learn from the
            // device instead of re-matching a stale name.
            additionalSettings:
                Map<String, dynamic>.from(existing.additionalSettings)
                  ..remove('installedPackageName')
                  ..remove('appLabel'),
          ),
        ));
        return;
      }
      if (existing != null) {
        final mergedGroups = {...existing.groups, ...tags}.toList();
        // Move any legacy group tag out of categories: the category UI prunes
        // names it doesn't know about, and a group tag must never be owned by it.
        final cleanedCategories = existing.categories
            .where((c) => !groupIds.contains(c))
            .toList();
        final groupsChanged = !_listEquals(existing.groups, mergedGroups);
        final categoriesChanged = !_listEquals(
          existing.categories,
          cleanedCategories,
        );
        final carriedPackage =
            carriedInstalledPackage[existing.id] ??
            existing.cachedInstalledPackageName;
        final packageChanged =
            carriedPackage != existing.cachedInstalledPackageName;
        // Only rewrite the app when something actually changed, so we never
        // clobber a user's pinned / renamed / reconfigured app on every launch.
        if (groupsChanged || categoriesChanged || packageChanged) {
          var merged = existing.copyWith(
            groups: mergedGroups,
            categories: cleanedCategories,
          );
          if (packageChanged) {
            merged = merged.copyWith(
              additionalSettings: {
                ...merged.additionalSettings,
                'installedPackageName': carriedPackage,
              },
            );
          }
          toSave.add(merged);
          updated++;
        }
      } else {
        toSave.add(parsed.copyWith(groups: tags));
        added++;
      }
    });

    if (adoptions.isNotEmpty) {
      // Re-pointing means the old record goes away; its cached APK/icon are
      // named by the old ID so they are dropped too (a fresh download under the
      // new ID follows).
      await removeApps(adoptions.map((a) => a.stored.id).toList());
      AppLogger.info(
        'Adopted list.json package ID for ${adoptions.length} app(s): '
        '${adoptions.map((a) => '${a.stored.id}->${a.adopted.id}').join(', ')}',
      );
      toSave.addAll(adoptions.map((a) => a.adopted));
    }

    if (toSave.isNotEmpty) {
      await waitForAppsToLoad();
      await saveApps(toSave, onlyIfExists: false, reuseInstalledInfo: true);
    }
    if (groupMeta.isNotEmpty) {
      settingsProvider.groupedListGroups = groupMeta;
    }
    return (
      added: added,
      updated: updated + adoptions.length,
      suppressed: suppressed,
    );
  }

  /// Pulls the grouped app list (`list.json`) and merges it into the store.
  ///
  /// Only ever called from the user's action in Settings - it used to run on
  /// every startup, which re-added apps the user had deleted. Tries the
  /// configured URL, then a proxy mirror of it, then the bundled
  /// `assets/list.json` so the groups still work offline.
  Future<({String source, int added, int updated, int suppressed})>
  syncGroupedList() async {
    final url = settingsProvider.groupedListUrl;
    // Reuse the LAN repository's DNS-SD discovery. Its HTTP root serves both
    // the F-Droid index and the ObtainAPK grouped-list contract at /list.json.
    final candidateUrls = <String>[];
    try {
      final lanBase = await const MethodChannel(
        'com.pt123123.obtainapk/lan_repo_discovery',
      ).invokeMethod<String>('discover').timeout(const Duration(seconds: 2));
      if (lanBase != null && lanBase.isNotEmpty) {
        candidateUrls.add(
          '${lanBase.replaceFirst(RegExp(r'/+$'), '')}/list.json',
        );
      }
    } catch (e) {
      AppLogger.info('LAN grouped-list discovery unavailable: $e');
    }
    candidateUrls.addAll([url, 'https://ghproxy.com/$url']);
    final failures = <String>[];
    String? raw;
    var source = '';
    for (final u in candidateUrls) {
      try {
        final resp = await http
            .get(Uri.parse(u))
            .timeout(const Duration(seconds: 12));
        if (resp.statusCode >= 200 &&
            resp.statusCode < 300 &&
            resp.body.trim().isNotEmpty) {
          raw = resp.body;
          source = u;
          break;
        }
        failures.add('$u → HTTP ${resp.statusCode}');
      } catch (e) {
        AppLogger.warn('Grouped list fetch failed for $u: $e');
        failures.add('$u → $e');
      }
    }
    if (raw == null) {
      raw = await rootBundle
          .loadString('assets/list.json')
          .catchError((_) => '');
      source = 'assets/list.json';
    }
    if (raw.trim().isEmpty) {
      throw ObtainiumError('${tr('failedToImport')}: ${failures.join('; ')}');
    }
    final merged = await mergeGroupedList(raw);
    settingsProvider.recordGroupedListSync(
      added: merged.added,
      updated: merged.updated,
      suppressed: merged.suppressed,
      source: source,
    );
    AppLogger.info(
      'Merged grouped list from $source: '
      '${merged.added} added, ${merged.updated} updated, '
      '${merged.suppressed} skipped as removed',
    );
    return (
      source: source,
      added: merged.added,
      updated: merged.updated,
      suppressed: merged.suppressed,
    );
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _applyImportedSettings(Map<String, dynamic> settingsMap) {
    settingsMap.forEach((key, value) {
      if (value is int) {
        settingsProvider.prefs?.setInt(key, value);
      } else if (value is double) {
        settingsProvider.prefs?.setDouble(key, value);
      } else if (value is bool) {
        settingsProvider.prefs?.setBool(key, value);
      } else if (value is List) {
        settingsProvider.prefs?.setStringList(
          key,
          value.whereType<String>().toList(),
        );
      } else if (value is String) {
        settingsProvider.setSettingString(key, value);
      }
    });
  }
}

const int currentExportSchemaVersion = 2;
const String kPackageVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.0.0',
);

class ExportSchema {
  final int schemaVersion;
  final String exportedAt;
  final String appVersion;
  final List<Map<String, dynamic>> apps;
  final Map<String, dynamic>? settings;

  ExportSchema({
    required this.schemaVersion,
    required this.exportedAt,
    required this.appVersion,
    required this.apps,
    this.settings,
  });

  factory ExportSchema.fromJson(Map<String, dynamic> json) {
    final schemaVersion = json['schemaVersion'] as int? ?? 1;
    if (schemaVersion > currentExportSchemaVersion) {
      throw FormatException(
        'Export was created by a newer version of Obtainium '
        '(schema v$schemaVersion, current is v$currentExportSchemaVersion). '
        'Please update Obtainium to import this file.',
      );
    }
    return ExportSchema(
      schemaVersion: schemaVersion,
      exportedAt: json['exportedAt'] as String? ?? '',
      appVersion: json['appVersion'] as String? ?? '',
      apps:
          (json['apps'] as List<dynamic>?)
              ?.map((e) => e as Map<String, dynamic>)
              .toList() ??
          [],
      settings: json['settings'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': currentExportSchemaVersion,
    'exportedAt': exportedAt,
    'appVersion': appVersion,
    'apps': apps,
    'settings': settings,
  };
}

/// Decides which of the tracked-app IDs sharing one URL to keep and which to
/// drop, so the grouped-list merge can repair the placeholder-ID duplicates
/// earlier builds produced (the placeholder was renamed to the real package
/// name on install, and the next startup merge re-added the placeholder).
///
/// A real (non-placeholder) ID always wins — it is the one carrying install
/// state. When every ID is a placeholder the first one is kept. Two distinct
/// real IDs never count as duplicates: one repo legitimately serves two
/// packages.
(String, List<String>) resolveSameUrlDuplicates(
  List<String> ids,
  bool Function(String id) isPlaceholderId,
) {
  if (ids.length < 2) return (ids.first, const []);
  final realIds = ids.where((id) => !isPlaceholderId(id)).toList();
  if (realIds.length >= 2) return (realIds.first, const []);
  final keeperId = realIds.isNotEmpty ? realIds.first : ids.first;
  return (keeperId, ids.where((id) => id != keeperId).toList());
}

/// Whether a list.json entry's package [listId] should replace the [storedId]
/// the store currently uses for the same app URL.
///
/// Only a real rename qualifies: the two IDs differ, nothing is installed under
/// the old [storedId] (so re-pointing cannot orphan a live app), [listId] is not
/// already tracked by another record, and [listId] is a valid package id rather
/// than a fresh placeholder.
bool shouldAdoptListAppId({
  required String storedId,
  required String listId,
  required bool storedInstalled,
  required bool listIdAlreadyTracked,
}) {
  if (storedId == listId) return false;
  if (storedInstalled || listIdAlreadyTracked) return false;
  // A placeholder id (all-digits or 12-hex) is not a real package name, so it
  // must not be adopted as the app's ID.
  return !(RegExp(r'^[0-9]+$').hasMatch(listId) ||
      RegExp(r'^[0-9a-f]{12}$').hasMatch(listId));
}

/// Tombstones that still apply: an app removed from a grouped list stays out of
/// later syncs, but one whose URL is tracked again was clearly re-added by hand,
/// so its removal record is dropped.
List<String> resolveListSuppression({
  required List<String> suppressed,
  required Set<String> trackedUrls,
}) => suppressed.where((url) => !trackedUrls.contains(url)).toList();

/// Which of the removed apps were grouped-list apps.
///
/// Only those are recorded as removals: an app the user added by hand is
/// unrelated to `list.json` and must not be filtered out of a later sync. The
/// store's [App.groups] tags are what marks an entry as list-sourced.
List<String> groupedListUrlsOf(Iterable<App> apps) =>
    apps.where((a) => a.groups.isNotEmpty).map((a) => a.url).toList();
