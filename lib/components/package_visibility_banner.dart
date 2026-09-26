import 'package:android_intent_plus/android_intent.dart';
import 'package:android_package_manager/android_package_manager.dart';
import 'package:flutter/material.dart';

import 'package:obtainium/providers/settings_provider.dart';

/// 真实设备（含电视盒子）的系统包都有几十个以上；被拦截时通常只剩应用自己。
/// 阈值取得很小，避免在正常设备上误报。
const int minPlausibleInstalledPackages = 6;

/// 返回的已安装包数少到不可能是真实设备 → 视为被系统隐私层拦截。
///
/// Manifest 已声明 QUERY_ALL_PACKAGES 且系统层 granted=true，但小米
/// MIUI/HyperOS 在自家隐私层另有独立的「获取应用列表」开关（默认拒绝，
/// 不在标准 AppOps 里）。被拒时 PackageManager.getInstalledPackages 只返回
/// 应用自己：「全部应用」页只剩 1 个应用，所有跟踪应用都显示「未安装」。
bool isPackageListRestricted(List<PackageInfo> installedPackages) =>
    installedPackages.length < minPlausibleInstalledPackages;

/// 打开本应用的系统应用信息页，引导用户放行「获取应用列表」：
/// 权限管理 → 其他权限 → 获取应用列表 → 始终允许。
///
/// MIUI 的单应用权限编辑页（PermissionsEditorActivity）在 HyperOS 3 上
/// 未对第三方开放，拉起会被直接弹回，所以统一走应用信息页。
Future<void> openAppListPermissionSettings() async {
  await const AndroidIntent(
    action: 'action_application_details_settings',
    data: 'package:$obtainiumId',
  ).launch();
}

/// 「应用列表被系统拦截」提示横幅：说明影响并给出授权入口。
class PackageVisibilityBanner extends StatelessWidget {
  const PackageVisibilityBanner({super.key, this.onRecheck});

  /// 「重新检测」回调：用户授权返回后页面据此刷新并撤下横幅。
  final VoidCallback? onRecheck;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      color: cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Row(
              children: [
                Icon(
                  Icons.visibility_off_rounded,
                  size: 20,
                  color: cs.onSecondaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '系统拦截了应用列表读取',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: cs.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            Text(
              '小米系统的「获取应用列表」权限未放行，本应用只能看到自己：'
              '「全部应用」页不完整，所有跟踪应用都会显示为未安装。'
              '请在 应用信息 → 权限管理 → 其他权限 中允许「获取应用列表」。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSecondaryContainer,
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: openAppListPermissionSettings,
                  icon: const Icon(Icons.settings_rounded, size: 18),
                  label: const Text('去授权'),
                ),
                if (onRecheck != null)
                  TextButton.icon(
                    onPressed: onRecheck,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重新检测'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
