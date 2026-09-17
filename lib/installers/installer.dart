import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

/// Android PackageInstaller status codes: 0 = success, 3 = cancelled / pending.
const int _installSuccessCode = 0;
const int _installAlreadyPendingCode = 3;

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
  /// [_installSuccessCode] is a completed install, [_installAlreadyPendingCode]
  /// is a pending/no-op (e.g. already installed), a null code is treated as
  /// cancelled, and any other value is an error carrying the original code.
  factory InstallResult.fromPlatformCode(int? code) {
    if (code == null) {
      return InstallResult.cancelled();
    }
    if (code == _installAlreadyPendingCode) {
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

/// Human-readable Chinese description of a known Android PackageInstaller
/// error code. Falls back to a generic message carrying the raw code for
/// unknown values so the user still sees something useful.
String installErrorCodeToMessage(int code) {
  switch (code) {
    case -1:
      return 'APK 文件无效';
    case -2:
      return 'APK 文件损坏或格式不兼容';
    case -3:
      return '安装包中的 Provider 与现有应用冲突';
    case -4:
      return '无法解析安装包路径';
    case -5:
      return '缺少所需的共享库';
    case -6:
      return '替换现有应用时失败（无法删除旧版本）';
    case -7:
      return 'APK 优化 (dexopt) 失败，文件可能不完整';
    case -8:
      return '签名不匹配！请先卸载旧版本，或使用相同签名重新打包';
    case -9:
      return '共享用户 ID 不兼容';
    case -10:
      return '设备缺少此应用需要的功能（API/硬件）';
    case -11:
      return '存储容器错误（可能是内部存储问题）';
    case -12:
      return '存储空间不足，请清理后重试';
    case -13:
      return '已存在同名应用';
    case -14:
      return '此 APK 要求更高版本的 Android';
    case -15:
      return 'APK 与当前 Android 版本不兼容';
    case -16:
      return 'APK 完整性校验失败（可能被篡改或下载不完整）';
    case -17:
      return '应用包名或签名与之前安装的版本不同';
    case -18:
      return '安装被中途取消';
    case -100:
      return '内部安装器错误';
    case -101:
      return '存储空间不足';
    case -102:
      return '应用已被删除';
    case -103:
      return 'APK 过大，无法安装';
    case -104:
      return '安装参数无效';
    case -105:
      return '版本号格式无效';
    case -106:
      return '版本不兼容';
    case -107:
      return '无法降级安装，请先卸载旧版本';
    case -108:
      return 'APK 签名无效或损坏';
    case -109:
      return '缺少共享用户 ID';
    case -110:
      return '此 APK 是测试版，不允许正式安装';
    case -111:
      return 'CPU 架构不匹配（APK 不支持当前设备的 CPU 架构）';
    case -112:
      return '安装器内部错误';
    case -113:
      return '用户或设备策略禁止安装此应用';
    case -114:
      return 'APK 压缩包损坏';
    case -115:
      return '订阅安装不被允许';
    case -116:
      return '此设备不支持安装此应用';
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
