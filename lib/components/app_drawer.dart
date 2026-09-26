import 'package:material_ui/material_ui.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/utils/nav_helper.dart';
import 'package:provider/provider.dart';

/// 侧边栏导航的目标页。
enum ObtainDrawerPage { apps, allApps }

/// 侧边栏：在「应用列表」（主界面）与「全部应用」（设备上安装的全部应用，
/// 含系统应用）两个页面之间切换。
class ObtainAppDrawer extends StatelessWidget {
  const ObtainAppDrawer({super.key, this.activePage = ObtainDrawerPage.apps});

  /// 当前所在页，用来高亮对应入口并决定切换行为。
  final ObtainDrawerPage activePage;

  void _select(BuildContext context, ObtainDrawerPage target) {
    // 先收起侧边栏再切页面；drawer 不是路由，不能走 Navigator.pop。
    Scaffold.maybeOf(context)?.closeDrawer();
    if (target == activePage) return;
    switch (target) {
      case ObtainDrawerPage.apps:
        // 回主列表：弹掉压在根路由上的所有页面。
        Navigator.of(context).popUntil((route) => route.isFirst);
      case ObtainDrawerPage.allApps:
        NavHelper.pushAllAppsPage(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appsProvider = context.watch<AppsProvider>();
    final cs = Theme.of(context).colorScheme;
    final tracked = appsProvider.apps.length;
    final installed = appsProvider.apps.values
        .where((a) => a.installedInfo != null)
        .length;

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ObtainAPK',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tracked == 0
                        ? '在主界面添加要跟踪的应用'
                        : '已跟踪 $tracked 个应用 · $installed 个已安装',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                children: [
                  _NavTile(
                    icon: Icons.list_alt_rounded,
                    label: '应用列表',
                    subtitle: '正在跟踪更新的应用',
                    active: activePage == ObtainDrawerPage.apps,
                    onTap: () => _select(context, ObtainDrawerPage.apps),
                  ),
                  _NavTile(
                    icon: Icons.apps_rounded,
                    label: '全部应用',
                    subtitle: '设备上安装的全部应用（含系统应用）',
                    active: activePage == ObtainDrawerPage.allApps,
                    onTap: () => _select(context, ObtainDrawerPage.allApps),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  /// 是否为当前所在页；高亮成 M3 的 selected ListTile 样式。
  final bool active;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: trailing,
      selected: active,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      onTap: onTap,
    );
  }
}
