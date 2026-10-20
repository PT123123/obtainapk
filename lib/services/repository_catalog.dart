import 'dart:convert';

import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/near_source.dart';

class RepositoryCatalog {
  const RepositoryCatalog({
    required this.baseUrl,
    required this.fetchedAt,
    required this.apps,
    this.fromCache = false,
  });

  final String baseUrl;
  final DateTime fetchedAt;
  final List<App> apps;
  final bool fromCache;

  String get source =>
      fromCache ? '本地缓存（$baseUrl，${fetchedAt.toLocal()}）' : baseUrl;
}

/// The repository index is the catalog authority. Cache only fully parsed,
/// successful snapshots, and never substitute an unrelated repository cache.
class RepositoryCatalogService {
  RepositoryCatalogService(
    this.settings, {
    FDroidRepo? repo,
    Future<String> Function()? resolveBaseUrl,
  }) : _repo = repo ?? FDroidRepo(),
       _resolveBaseUrl = resolveBaseUrl ?? NearSource(settings).resolveBaseUrl;

  static const cacheKey = 'repositoryCatalogCacheV1';
  final SettingsProvider settings;
  final FDroidRepo _repo;
  final Future<String> Function() _resolveBaseUrl;

  Future<RepositoryCatalog> load() async {
    final configuredUrl = settings.lanRepoUrl;
    try {
      final base = await _resolveBaseUrl();
      final apps = await _repo.getCatalogApps(base, {
        'allowInsecure': true,
        'lanRepoRequest': true,
      });
      final fetchedAt = DateTime.now();
      final prefs = settings.prefs;
      if (prefs == null) throw StateError('Settings have not been initialized');
      final saved = await prefs.setString(
        cacheKey,
        jsonEncode({
          'schemaVersion': 1,
          'configuredUrl': configuredUrl,
          'baseUrl': base,
          'fetchedAt': fetchedAt.toIso8601String(),
          'apps': apps.map((app) => app.toJson()).toList(),
        }),
      );
      if (!saved) throw StateError('Failed to persist repository catalog');
      return RepositoryCatalog(baseUrl: base, fetchedAt: fetchedAt, apps: apps);
    } catch (error) {
      try {
        final raw = settings.prefs?.getString(cacheKey);
        if (raw != null) {
          final cache = jsonDecode(raw) as Map<String, dynamic>;
          if (cache['schemaVersion'] == 1 &&
              cache['configuredUrl'] == configuredUrl) {
            return RepositoryCatalog(
              baseUrl: cache['baseUrl'] as String,
              fetchedAt: DateTime.parse(cache['fetchedAt'] as String),
              apps: (cache['apps'] as List)
                  .map(
                    (app) =>
                        App.fromJson(Map<String, dynamic>.from(app as Map)),
                  )
                  .toList(),
              fromCache: true,
            );
          }
        }
      } catch (_) {
        // A broken cache must not be treated as an empty authoritative list.
      }
      throw ObtainiumError('无法获取仓库应用列表，且没有可用缓存：$error');
    }
  }
}

/// Installed and manually added apps survive repository removals. Legacy
/// grouped-list entries are managed too, so the old bundled catalog migrates.
bool shouldRemoveCatalogApp(
  App app, {
  required bool installed,
  required Set<String> publishedIds,
}) =>
    !publishedIds.contains(app.id) &&
    !installed &&
    (app.additionalSettings['repositoryManaged'] as bool? ??
        app.groups.isNotEmpty);

String catalogSuppressionKey(String packageId) => 'package:$packageId';

class CatalogMergePlan {
  final List<App> save = [];
  final Set<String> remove = {};
  int added = 0;
  int updated = 0;
  int suppressed = 0;
}

CatalogMergePlan planCatalogMerge(
  RepositoryCatalog catalog,
  Iterable<({App app, bool installed})> stored,
  Set<String> suppressed,
) {
  final plan = CatalogMergePlan();
  final records = stored.toList();
  final byId = {for (final record in records) record.app.id: record.app};
  final published = catalog.apps.map((app) => app.id).toSet();
  for (final incoming in catalog.apps) {
    var existing = byId[incoming.id];
    // Migrate a placeholder only with package identity learned from Android or
    // a previous LAN match, never by display name or source repository URL.
    if (existing == null) {
      for (final record in records) {
        final app = record.app;
        if (isTempId(app) &&
            (app.cachedInstalledPackageName == incoming.id ||
                app.additionalSettings['nearSourcePackageId'] == incoming.id)) {
          existing = app;
          plan.remove.add(app.id);
          break;
        }
      }
    }
    if (existing == null) {
      if (suppressed.contains(catalogSuppressionKey(incoming.id)) ||
          suppressed.contains(incoming.url)) {
        plan.suppressed++;
        continue;
      }
      plan.save.add(incoming);
      plan.added++;
      continue;
    }
    final managed =
        existing.additionalSettings['repositoryManaged'] as bool? ??
        existing.groups.isNotEmpty;
    plan.save.add(
      existing.copyWith(
        id: incoming.id,
        url: managed ? incoming.url : existing.url,
        overrideSource: managed
            ? incoming.overrideSource
            : existing.overrideSource,
        name: managed ? incoming.name : existing.name,
        author: managed ? incoming.author : existing.author,
        groups: managed ? incoming.groups : existing.groups,
        latestVersion: incoming.latestVersion,
        apkUrls: incoming.apkUrls,
        otherAssetUrls: const [],
        preferredApkIndex: 0,
        releaseDate: incoming.releaseDate,
        changeLog: incoming.changeLog,
        releaseUrl: incoming.releaseUrl,
        lastUpdateCheck: catalog.fetchedAt,
        additionalSettings: {
          ...existing.additionalSettings,
          if (managed) ...incoming.additionalSettings,
          'repositoryManaged': managed,
          'nearSourcePackageId': incoming.id,
        },
      ),
    );
    plan.updated++;
  }
  // A cached catalog is still a complete, previously validated repository
  // snapshot. Use it as the offline source of truth and prune stale managed
  // rows just as we do after a live fetch.
  for (final record in records) {
    if (shouldRemoveCatalogApp(
      record.app,
      installed: record.installed,
      publishedIds: published,
    )) {
      plan.remove.add(record.app.id);
    }
  }
  return plan;
}
