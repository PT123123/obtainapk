import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

/// Raw Android PackageInstaller status codes (PackageInstaller.EXTRA_STATUS),
/// as forwarded by the vendored android_package_installer plugin.
const int _installSuccessCode = 0; // STATUS_SUCCESS
const int _installPendingUserActionCode = -1; // STATUS_PENDING_USER_ACTION

enum InstallOutcome { success, cancelled, error }

/// Unified result of an install operation, replacing the previous
/// "nullable int code" pattern used by the platform install APIs.
class InstallResult {
  final InstallOutcome outcome;
  final int? errorCode;

  const InstallResult({required this.outcome, this.errorCode});

  factory InstallResult.success() =>
      const InstallResult(outcome: InstallOutcome.success);

  factory InstallResult.cancelled() =>
      const InstallResult(outcome: InstallOutcome.cancelled);

  factory InstallResult.error(int code) =>
      InstallResult(outcome: InstallOutcome.error, errorCode: code);

  /// Maps a raw platform install status code to an [InstallResult].
  /// [_installPendingUserActionCode] is consumed by the plugin (it launches
  /// the confirmation dialog), but treat it defensively as cancelled. A null
  /// code means the result was lost; everything else is an error carrying
  /// the original code.
  factory InstallResult.fromPlatformCode(int? code) {
    if (code == null || code == _installPendingUserActionCode) {
      return InstallResult.cancelled();
    }
    if (code == _installSuccessCode) {
      return InstallResult.success();
    }
    return InstallResult.error(code);
  }

  bool get isSuccess => outcome == InstallOutcome.success;
  bool get isError => outcome == InstallOutcome.error;
}

/// Human-readable Chinese description of a raw Android PackageInstaller
/// status code (PackageInstaller.EXTRA_STATUS), with MIUI/HyperOS-specific
/// hints where the system is known to abort or block installs silently.
String installErrorCodeToMessage(int code) {
  switch (code) {
    case -2:
      return '安装失败（系统未说明原因，可尝试重新下载安装）';
    case -3:
      return '安装被中止：你在系统弹窗中取消了安装，或系统拦截了本次安装';
    case -4:
      return '安装被系统拦截：MIUI/澎湃OS 请允许「安装未知应用」，并关闭「纯净模式」；也可能是存储空间不足';
    case -5:
      return '与已安装应用冲突（签名不一致），请先卸载旧版本再安装';
    case -6:
      return 'APK 文件无效或已损坏，请重新下载';
    case -7:
      return '与设备不兼容，或与已安装版本签名冲突（INSTALL_FAILED_UPDATE_INCOMPATIBLE，请先卸载旧版本）';
    case -8:
      return '存储空间不足，或共享用户 ID 不兼容，请清理后重试';
    case -9:
      return '安装超时，请重试';
    default:
      return '安装失败 (code $code)';
  }
}

/// Strategy that performs the platform-specific parts of an app installation.
///
/// Implementations are intentionally thin: the surrounding harness in
/// [AppsProvider] handles download validation, downgrade checks, the background
/// completion workaround, persistence, file cleanup, and notifications. An
/// installer only decides silent-install eligibility, manages its own
/// permissions, and performs the terminal platform call.
abstract class Installer {
  final SettingsProvider settingsProvider;

  Installer(this.settingsProvider);

  /// Unique key identifying this installer mode (e.g. 'stock', 'shizuku',
  /// 'external').
  String get modeKey;

  /// Whether directory/bundle installs should hand off the original container
  /// file (XAPK/ZIP/tarball) rather than extracted split APKs.
  bool get wantsContainerHandoff => false;

  /// The installer-specific portion of the silent-install decision. Shared
  /// pre-checks (background updates enabled, exemptions, multi-URL, target SDK)
  /// are handled by the caller before this is invoked.
  Future<bool> canInstallSilently(App app);

  /// Whether the installer currently has the privileges needed to install
  /// without prompting the user. Does not prompt.
  Future<bool> checkPermission();

  /// Ensures the installer has the privileges needed to install, prompting the
  /// user if necessary. Throws an [ObtainiumError] if permission is denied.
  Future<void> ensurePermission();

  /// Installs one or more APK file paths (a base APK plus optional splits).
  /// [installOptions] carries installer-specific key-value flags (e.g. Shizuku's
  /// `shizukuPretendToBeGooglePlay`).
  Future<InstallResult> installApk(
    List<String> apkFilePaths, {
    required String appId,
    Map<String, dynamic> installOptions = const {},
  });
}
