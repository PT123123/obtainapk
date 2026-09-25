import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/app_list_tile.dart' show AppIconWidget;
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/version_service.dart';
import 'package:obtainium/utils/nav_helper.dart';
import 'package:provider/provider.dart';

/// 侧边栏（drawer）：可展开的应用列表，展示每个应用的图标与详细信息
/// （跟踪 ID、设备上的真实包名、版本、来源、分组）。
///
/// 列表同时是"应用匹配缓存"的可视化入口：仅凭地址添加的应用一开始只有
/// 占位 ID，无法对应到设备上已安装的包；当通过本应用安装覆盖（或按名称
/// 匹配）后，真实包名会被学习并持久化到 additionalSettings
/// （`installedPackageName` / `appLabel`），此后即使跟踪 ID 与包名不同，
/// 也能稳定对应到同一个已安装应用。匹配状态行就是这条缓存的展示。
class ObtainAppDrawer extends StatefulWidget {
  const ObtainAppDrawer({super.key});

  @override
  State<ObtainAppDrawer> createState() => _ObtainAppDrawerState();
}

class _ObtainAppDrawerState extends State<ObtainAppDrawer> {
  String _query = '';

  /// 搜索框按空白拆词，每个词都要命中名称 / ID / 包名 / 标签之一，
  /// 与主列表的搜索语义一致。
  bool _matchesQuery(AppInMemory a, String realPackage) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    final haystacks = [
      a.name,
      a.app.finalAuthor,
      a.app.id,
      realPackage,
      if (a.app.cachedAppLabel != null) a.app.cachedAppLabel!,
      a.app.url,
    ].map((e) => e.toLowerCase()).toList();
    return query
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .every((token) => haystacks.any((h) => h.contains(token)));
  }

  void _copy(String label, String value) {
    unawaited(Clipboard.setData(ClipboardData(text: value)));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制$label'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _openAppPage(String appId) {
    // 先收起侧边栏再推页面；drawer 不是路由，不能走 Navigator.pop。
    Scaffold.maybeOf(context)?.closeDrawer();
    NavHelper.pushAppPage(context, appId);
  }

  @override
  Widget build(BuildContext context) {
    final appsProvider = context.watch<AppsProvider>();
    final settingsProvider = context.watch<SettingsProvider>();
    final cs = Theme.of(context).colorScheme;
    final apps = appsProvider.apps.values.toList()
      ..sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    final visible = apps
        .where((a) => _matchesQuery(a, a.installedInfo?.packageName ?? ''))
        .toList();
    final installedCount = apps.where((a) => a.installedInfo != null).length;

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '应用列表',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '共 ${apps.length} 个应用 · $installedCount 个已安装'
                    '${apps.length - installedCount > 0 ? ' · ${apps.length - installedCount} 个待匹配' : ''}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search),
                      hintText: '搜索名称 / ID / 包名',
                      border: const OutlineInputBorder(),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => setState(() => _query = ''),
                            ),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ],
              ),
            ),
            const Divider(height: 24),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Text(
                        apps.isEmpty ? '暂无应用' : '没有匹配的应用',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: visible.length,
                      itemBuilder: (context, i) => _AppDrawerTile(
                        key: ValueKey(visible[i].app.id),
                        appInMemory: visible[i],
                        appsProvider: appsProvider,
                        settingsProvider: settingsProvider,
                        onOpen: () => _openAppPage(visible[i].app.id),
                        onCopy: _copy,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppDrawerTile extends StatelessWidget {
  final AppInMemory appInMemory;
  final AppsProvider appsProvider;
  final SettingsProvider settingsProvider;
  final VoidCallback onOpen;
  final void Function(String label, String value) onCopy;

  const _AppDrawerTile({
    super.key,
    required this.appInMemory,
    required this.appsProvider,
    required this.settingsProvider,
    required this.onOpen,
    required this.onCopy,
  });

  App get _app => appInMemory.app;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final realPackage = appInMemory.installedInfo?.packageName;
    final status = _matchStatusFor(context, realPackage);
    final hasUpdate = isAppUpdateable(_app, settingsProvider);
    final valueStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
    );

    return ExpansionTile(
      leading: AppIconWidget(
        appId: _app.id,
        installed: appInMemory.installedInfo != null,
        appsProvider: appsProvider,
        size: 36,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              appInMemory.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hasUpdate)
            Tooltip(
              message: '有可用更新',
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: cs.error,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        realPackage ?? _app.id,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: cs.onSurfaceVariant,
        ),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            _detailRow(
              '匹配状态',
              status.label,
              valueColor: status.color,
              style: valueStyle,
            ),
            _copyableRow(
              context,
              '跟踪 ID',
              _app.id,
              valueStyle,
              () => onCopy('跟踪 ID', _app.id),
            ),
            _copyableRow(
              context,
              '设备包名',
              realPackage ?? _app.cachedInstalledPackageName ?? '—',
              valueStyle,
              realPackage != null
                  ? () => onCopy('设备包名', realPackage)
                  : null,
            ),
            _detailRow(
              '版本',
              _app.installedVersion == null
                  ? '未安装 · 最新 ${_app.latestVersion}'
                  : '已装 ${_app.installedVersion} · 最新 ${_app.latestVersion}',
              style: valueStyle,
            ),
            _detailRow(
              '来源',
              _app.url,
              style: valueStyle,
            ),
            if (_app.groups.isNotEmpty)
              _detailRow('分组', _app.groups.join('、'), style: valueStyle),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('查看应用详情'),
            ),
          ],
        ),
      ],
    );
  }

  ({String label, Color? color}) _matchStatusFor(
    BuildContext context,
    String? realPackage,
  ) {
    if (realPackage == null) return (label: '未安装', color: null);
    final cs = Theme.of(context).colorScheme;
    if (realPackage == _app.id) {
      return (label: '已安装 · ID 精确匹配', color: cs.primary);
    }
    final cached = _app.cachedInstalledPackageName;
    if (cached != null && cached == realPackage) {
      return (label: '已安装 · 匹配缓存（安装后学到的包名）', color: cs.tertiary);
    }
    return (label: '已安装 · 按名称匹配', color: cs.tertiary);
  }

  Widget _detailRow(
    String label,
    String value, {
    Color? valueColor,
    TextStyle? style,
  }) {
    final effectiveStyle = (style ?? const TextStyle(fontSize: 12))
        .copyWith(color: valueColor ?? style?.color);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: effectiveStyle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _copyableRow(
    BuildContext context,
    String label,
    String value,
    TextStyle? style,
    VoidCallback? onCopy,
  ) {
    final canCopy = onCopy != null && value != '—';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: (style ?? const TextStyle(fontSize: 12)).copyWith(
              fontFamily: 'monospace',
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (canCopy)
          GestureDetector(
            onTap: onCopy,
            child: Icon(
              Icons.copy_rounded,
              size: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
