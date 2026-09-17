import 'dart:async';

import 'package:android_package_installer/android_package_installer.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/installers/install_utils.dart';
import 'package:obtainium/installers/installer.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/external_install_bridge.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/utils/string_utils.dart';

const int _androidApiLevelS = 31;

/// Installs using Android's session-based [AndroidPackageInstaller]. Requires
/// the `REQUEST_INSTALL_PACKAGES` permission and, for silent installs, that
/// Obtainium is the installing package on a new enough OS.
class StockInstaller extends Installer {
  StockInstaller(super.settingsProvider);

  @override
  String get modeKey => 'stock';

  @override
  Future<bool> canInstallSilently(App app) async {
    if (isObtainiumVariant(app.id)) {
      AppLogger.info(
        'App will not be installed silently: Obtainium cannot silently install itself: ${app.id}',
      );
      return false;
    }
    final osInfo = await DeviceInfoPlugin().androidInfo;
    String? installerPackageName;
    try {
      installerPackageName = osInfo.version.sdkInt >= 30
          ? (await packageManager.getInstallSourceInfo(
              packageName: app.id,
            ))?.installingPackageName
          : (await packageManager.getInstallerPackageName(packageName: app.id));
    } catch (e) {
      AppLogger.info(
        'App will not be installed silently: failed to get installed package details: ${app.id} (${e.toString()})',
      );
      return false;
    }
    if (installerPackageName == null ||
        !isObtainiumVariant(installerPackageName)) {
      // If we did not install the app, silent install is not possible
      AppLogger.info(
        'App will not be installed silently: Obtainium is not the installing package (current installer: $installerPackageName): ${app.id}',
      );
      return false;
    }
    if (osInfo.version.sdkInt < _androidApiLevelS) {
      // The OS must also be new enough
      AppLogger.info(
        'App will not be installed silently: Android SDK ${osInfo.version.sdkInt} is too old (requires $_androidApiLevelS+): ${app.id}',
      );
      return false;
    }
    // Session installer silent installs require a recent enough target SDK;
    // this constraint is specific to the stock installer.
    // https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams#setRequireUserAction(int)
    final int? targetSDK = (await getInstalledInfo(
      app.id,
    ))?.applicationInfo?.targetSdkVersion;
    final int requiredSDK = osInfo.version.sdkInt - 3;
    if (!(targetSDK != null && targetSDK >= requiredSDK)) {
      AppLogger.info(
        'App will not be installed silently: currently targets API $targetSDK which is too low (requires API $requiredSDK): ${app.id}',
      );
      return false;
    }
    return true;
  }

  @override
  Future<bool> checkPermission() =>
      settingsProvider.getInstallPermission(enforce: false);

  @override
  Future<void> ensurePermission() async {
    if (!(await settingsProvider.getInstallPermission(enforce: false))) {
      throw ObtainiumError(tr('installPermissionNotGranted'));
    }
  }

  @override
  Future<InstallResult> installApk(
    List<String> apkFilePaths, {
    required String appId,
    Map<String, dynamic> installOptions = const {},
  }) async {
    // Foreground installs must NOT use the PackageInstaller session flow:
    // MIUI/HyperOS both suppress and focus-kill session confirmation dialogs
    // from non-privileged installers within ~100ms, so the user never sees
    // any dialog and the session aborts. A plain ACTION_VIEW handoff via
    // startActivityForResult (like every APK installer app) is reliable:
    // the system installer runs inside our task and shows its own UI with
    // proper error reasons. Background auto-updates keep silent sessions.
    final silent = installOptions['silent'] != false;
    if (!silent && apkFilePaths.length == 1) {
      final baseline = await captureInstallBaseline(appId);
      final contentUri = await ExternalInstallerBridge.instance
          .contentUriForFile(apkFilePaths.first);
      if (contentUri == null) {
        throw ObtainiumError(tr('badDownload'));
      }
      AppLogger.info(
        'Foreground install of $appId handed to the system installer via ACTION_VIEW.',
      );
      final res = await ExternalInstallerBridge.instance.launchInstallIntent(
        uri: contentUri,
        type: 'application/vnd.android.package-archive',
        expectedPackageName: appId,
      );
      if (res == null) {
        // Result tracking unavailable: fall back to bounded polling.
        final installed = await waitForPackageInstall(
          appId,
          baseline,
          attempts: 60,
        );
        return installed ? InstallResult.success() : InstallResult.cancelled();
      }
      final verified = await waitForPackageInstall(
        appId,
        baseline,
        attempts: res.installed ? 60 : 2,
      );
      if (verified) {
        return InstallResult.success();
      }
      if (res.errorCode != null) {
        AppLogger.warn(
          'System installer reported failure for $appId (code ${res.errorCode}).',
        );
        return InstallResult.error(res.errorCode!);
      }
      return InstallResult.cancelled();
    }
    final code = await AndroidPackageInstaller.installApk(
      apkFilePath: apkFilePaths.join(','),
      silent: silent,
    );
    return InstallResult.fromPlatformCode(code);
  }
}
