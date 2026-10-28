import 'dart:async';

import 'package:flutter/services.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/settings_provider.dart';

class NearSourceResolution {
  const NearSourceResolution({required this.packageId, required this.apk});

  final String packageId;
  final APKDetails apk;
}

/// The LAN F-Droid repository (near source) published by `lanpub serve`.
///
/// An app uses this repository when the index owns it (`repositoryManaged`, the
/// same flag that puts the row in the 局域网库), never because of the global
/// remote-source switch: a legacy GitHub row would only ever fail here, since
/// the repository does not publish that package.
class NearSource {
  static const _repoRequestTimeout = Duration(seconds: 2);
  static const _repoRequestSettings = <String, dynamic>{
    'allowInsecure': true,
    'lanRepoRequest': true,
  };
  NearSource(this._settingsProvider);

  static const _discoveryChannel = MethodChannel(
    'com.pt123123.obtainapk/lan_repo_discovery',
  );
  static String? _lastDiscoveredBaseUrl;
  static DateTime? _lastDiscoveryAt;
  static Future<String>? _discoveryInFlight;

  final SettingsProvider _settingsProvider;

  String get baseUrl => _settingsProvider.lanRepoUrl;

  Future<String> resolveBaseUrl() async {
    final configured = baseUrl;
    if (configured.isNotEmpty) return configured;
    final lastDiscoveryAt = _lastDiscoveryAt;
    if (_lastDiscoveredBaseUrl != null &&
        lastDiscoveryAt != null &&
        DateTime.now().difference(lastDiscoveryAt) <
            const Duration(seconds: 60)) {
      return _lastDiscoveredBaseUrl!;
    }
    final running = _discoveryInFlight;
    if (running != null) return running;
    final discovery = _discoverBaseUrl();
    _discoveryInFlight = discovery;
    try {
      return await discovery;
    } finally {
      if (identical(_discoveryInFlight, discovery)) {
        _discoveryInFlight = null;
      }
    }
  }

  void invalidateDiscovery() {
    _lastDiscoveredBaseUrl = null;
    _lastDiscoveryAt = null;
  }

  Future<String> _discoverBaseUrl() async {
    try {
      final discovered = await _discoveryChannel
          .invokeMethod<String>('discover')
          .timeout(_repoRequestTimeout);
      if (discovered != null && discovered.isNotEmpty) {
        _lastDiscoveredBaseUrl = discovered;
        _lastDiscoveryAt = DateTime.now();
        return discovered;
      }
    } on PlatformException catch (e) {
      throw ObtainiumError('未发现局域网仓库：${e.message ?? e.code}');
    } on TimeoutException {
      throw ObtainiumError('发现局域网仓库超时（2 秒），请确认电脑上的 lanpub serve 正在运行');
    }
    throw ObtainiumError('未发现局域网仓库，请确认电脑上的 lanpub serve 正在运行');
  }

  /// Whether [app] is updated from the repository: the index owns it, or its
  /// URL already points inside the repository. The GitHub-source switch does
  /// not move repository packages over to the remote.
  bool isUsedFor(App app) =>
      app.additionalSettings['repositoryManaged'] == true || isNearUrl(app.url);

  /// True when [url] lives inside the repository, so it must not be rewritten
  /// by the app's declared (GitHub) source prefix or by download mirrors.
  bool isNearUrl(String url) {
    final configured = baseUrl;
    final discovered = _lastDiscoveredBaseUrl;
    return (configured.isNotEmpty && url.startsWith('$configured/')) ||
        (discovered != null && url.startsWith('$discovered/'));
  }

  /// The number of apps the repository publishes, or a thrown error describing
  /// why it could not be reached. Used by Settings → 应用来源 to show whether the
  /// LAN server is up before every app check fails on it.
  Future<int> probe() async => FDroidRepo()
      .countPublishedApps(await resolveBaseUrl(), _repoRequestSettings)
      .timeout(_repoRequestTimeout);

  /// Known package IDs take precedence over cached name matches. Placeholders
  /// use the package learned from the device, LAN match, or explicit source ID.
  static String? packageOf(App app) {
    final candidates = <String?>[
      isTempId(app) ? null : app.id,
      app.cachedInstalledPackageName,
      app.additionalSettings['nearSourcePackageId'] as String?,
      app.additionalSettings['appIdOrName'] as String?,
    ];
    for (final candidate in candidates) {
      if (candidate != null && candidate.contains('.')) return candidate;
    }
    return null;
  }

  /// Resolves [app] against the repository index.
  ///
  /// A package the repository doesn't publish throws instead of falling back to
  /// the remote: silently fetching from GitHub would hide that the near repo is
  /// missing the build.
  Future<NearSourceResolution> resolve(App app) async {
    final repo = FDroidRepo();
    final repoBaseUrl = await resolveBaseUrl();
    var package = packageOf(app);
    final names = <String>[
      app.finalName,
      app.cachedAppLabel ?? '',
      _sourceRepositoryName(app.url) ?? '',
    ];
    package ??= await _packageFromExactName(repo, app, names, repoBaseUrl);
    try {
      final apk = await _getPackageDetails(repo, package, repoBaseUrl);
      return NearSourceResolution(packageId: package, apk: apk);
    } on ObtainiumError catch (e) {
      if (e.code != 'APP_NOT_IN_REPO') rethrow;
      // A known package is an identity, not a search hint. A similarly named
      // fork must be added separately instead of offered as its update.
      if (isTempId(app) && app.cachedInstalledPackageName == null) {
        final matches = await repo.findAppsByExactName(
          repoBaseUrl,
          names,
          _repoRequestSettings,
        );
        if (matches.length == 1 && matches.single.key != package) {
          package = matches.single.key;
          final apk = await _getPackageDetails(repo, package, repoBaseUrl);
          return NearSourceResolution(packageId: package, apk: apk);
        }
        if (matches.length > 1) throw _ambiguousNameError(app, matches);
      }
      throw ObtainiumError(
        '近端仓库 $repoBaseUrl 里没有 $package。\n'
        '请用 lanpub add 把这个包投进仓库。',
        code: 'NEAR_SOURCE_APP_NOT_FOUND',
      );
    }
  }

  Future<String> _packageFromExactName(
    FDroidRepo repo,
    App app,
    List<String> names,
    String repoBaseUrl,
  ) async {
    final matches = await repo.findAppsByExactName(
      repoBaseUrl,
      names,
      _repoRequestSettings,
    );
    if (matches.length == 1) return matches.single.key;
    if (matches.length > 1) throw _ambiguousNameError(app, matches);
    throw ObtainiumError(
      '近端仓库无法按名称「${app.finalName}」自动匹配包名。'
      '请先安装该应用以便自动识别，或在应用设置中填写包名。',
      code: 'NEAR_SOURCE_APP_NOT_FOUND',
    );
  }

  String? _sourceRepositoryName(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return null;
    final last = uri.pathSegments.last.replaceFirst(
      RegExp(r'\.git$', caseSensitive: false),
      '',
    );
    return last.isEmpty ? null : last;
  }

  ObtainiumError _ambiguousNameError(
    App app,
    List<MapEntry<String, String>> matches,
  ) {
    final choices = matches.map((entry) => '${entry.value} (${entry.key})');
    return ObtainiumError(
      '「${app.finalName}」在近端仓库中匹配到多个应用：'
      '${choices.join('、')}。请在应用设置中填写正确的包名。',
    );
  }

  Future<APKDetails> _getPackageDetails(
    FDroidRepo repo,
    String package,
    String repoBaseUrl,
  ) => repo
      .getLatestAPKDetails('$repoBaseUrl/?appId=$package', <String, dynamic>{
        'appIdOrName': package,
        'allowInsecure': true,
        'lanRepoRequest': true,
        'trySelectingSuggestedVersionCode': true,
      });
}
