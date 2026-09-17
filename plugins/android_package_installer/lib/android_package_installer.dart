import 'package:android_package_installer/src/installer_platform.dart';

export 'package:android_package_installer/src/enums.dart';

class AndroidPackageInstaller {
  /// Installs apk file using Android Package Manager.
  /// Creates Package Installer session, then displays a dialog to confirm the installation.
  /// After installation process is completed, the session is closed.
  /// [apkFilePath] - the path to the apk package file. Example: /sdcard/Download/app.apk
  /// [silent] - request a user-action-free session. HyperOS/MIUI aborts such
  /// sessions from non-privileged installers, so pass false for foreground
  /// installs to get the standard system confirmation dialog.
  /// Returns session result code (raw PackageInstaller.EXTRA_STATUS value).
  static Future<int?> installApk({
    required String apkFilePath,
    bool silent = true,
  }) {
    Future<int?> code = AndroidPackageInstallerPlatform.instance.installApk(
      apkFilePath,
      silent: silent,
    );
    return code;
  }
}
