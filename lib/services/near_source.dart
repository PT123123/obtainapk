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
/// ObtainAPK resolves every app through it. The remote sources (GitHub and each
/// app's own site) are only used when the user declares it — globally via
/// Settings → 应用来源, or per app through `useRemoteSource`.
class NearSource {
  NearSource(this._settingsProvider);

  final SettingsProvider _settingsProvider;

  String get baseUrl => _settingsProvider.lanRepoUrl;

  /// True when the near source should answer for [app] — i.e. it hasn't been
  /// declared remote and a repository address is configured.
  bool isUsedFor(App app) =>
      !_settingsProvider.githubSourceEnabled &&
      !isDeclaredRemote(app) &&
      Uri.tryParse(baseUrl)?.hasAuthority == true;

  bool isDeclaredRemote(App app) =>
      app.additionalSettings['useRemoteSource'] == true;

  /// True when [url] lives inside the repository, so it must not be rewritten
  /// by the app's declared (GitHub) source prefix or by download mirrors.
  bool isNearUrl(String url) => url.startsWith('$baseUrl/');

  /// The number of apps the repository publishes, or a thrown error describing
  /// why it could not be reached. Used by Settings → 应用来源 to show whether the
  /// LAN server is up before every app check fails on it.
  Future<int> probe() => FDroidRepo().countPublishedApps(
    baseUrl,
    <String, dynamic>{'allowInsecure': true},
  );

  /// The package name used to look [app] up in the index: the name learned from
  /// the device, a saved LAN match, a real tracked ID, or an explicit source ID.
  static String? packageOf(App app) {
    final candidates = <String?>[
      app.cachedInstalledPackageName,
      app.additionalSettings['nearSourcePackageId'] as String?,
      isTempId(app) ? null : app.id,
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
    var package = packageOf(app);
    final names = <String>[app.finalName, app.cachedAppLabel ?? ''];
    package ??= await _packageFromExactName(repo, app, names);
    try {
      final apk = await _getPackageDetails(repo, package);
      return NearSourceResolution(packageId: package, apk: apk);
    } on ObtainiumError catch (e) {
      if (e.code != 'APP_NOT_IN_REPO') rethrow;
      final matches = await repo.findAppsByExactName(
        baseUrl,
        names,
        <String, dynamic>{'allowInsecure': true},
      );
      if (matches.length == 1 && matches.single.key != package) {
        package = matches.single.key;
        final apk = await _getPackageDetails(repo, package);
        return NearSourceResolution(packageId: package, apk: apk);
      }
      if (matches.length > 1) throw _ambiguousNameError(app, matches);
      throw ObtainiumError(
        '近端仓库 $baseUrl 里没有 $package。\n'
        '要么用 lanpub add 把这个包投进仓库，要么在这个应用的设置里勾选'
        '「改用远端源」。',
      );
    }
  }

  Future<String> _packageFromExactName(
    FDroidRepo repo,
    App app,
    List<String> names,
  ) async {
    final matches = await repo.findAppsByExactName(
      baseUrl,
      names,
      <String, dynamic>{'allowInsecure': true},
    );
    if (matches.length == 1) return matches.single.key;
    if (matches.length > 1) throw _ambiguousNameError(app, matches);
    throw ObtainiumError(
      '近端仓库无法按名称「${app.finalName}」自动匹配包名。'
      '请先安装该应用以便自动识别，或在应用设置中填写包名。',
    );
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

  Future<APKDetails> _getPackageDetails(FDroidRepo repo, String package) =>
      repo.getLatestAPKDetails('$baseUrl/?appId=$package', <String, dynamic>{
        'appIdOrName': package,
        'allowInsecure': true,
        'trySelectingSuggestedVersionCode': true,
      });
}
