import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_package_manager/android_package_manager.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/app_drawer.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/utils/format_utils.dart';
import 'package:share_plus/share_plus.dart';

/// PackageManager 里没有暴露的 ApplicationInfo.flag 常量。
/// https://developer.android.com/reference/android/content/pm/ApplicationInfo#FLAG_SYSTEM
const int _flagSystem = 0x00000001;
const int _flagUpdatedSystemApp = 0x00000080;

/// 「全部应用」页：设备上安装的全部应用（含系统应用）及其详细参数。
///
/// 数据来自 PackageManager.getInstalledPackages（已声明 QUERY_ALL_PACKAGES）。
/// 应用名与图标是每包一次的平台调用，因此分批渐进加载：列表先按包名渲染，
/// 名称全部加载完后再按显示名重排一次。
class AllAppsPage extends StatefulWidget {
  const AllAppsPage({super.key});

  @override
  State<AllAppsPage> createState() => _AllAppsPageState();
}

enum _TypeFilter { all, user, system }

enum _SortMode { name, updateTime, installTime, size }

String _sortModeLabel(_SortMode mode) => switch (mode) {
  _SortMode.name => '按名称',
  _SortMode.updateTime => '按更新时间',
  _SortMode.installTime => '按安装时间',
  _SortMode.size => '按 APK 大小',
};

class _AllAppsPageState extends State<AllAppsPage>
    with WidgetsBindingObserver {
  List<PackageInfo>? _packages;
  final Map<String, String> _labels = {};
  bool _labelsLoaded = false;
  final Map<String, int> _sizes = {};
  bool _sizesLoaded = false;
  String _query = '';
  _TypeFilter _filter = _TypeFilter.all;
  _SortMode _sortMode = _SortMode.name;

  /// 发起系统卸载后置位；回到前台时据此全量重查列表。
  bool _pendingRecheck = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pendingRecheck) {
      _pendingRecheck = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final packages = await getAllInstalledInfo();
    if (!mounted) return;
    setState(() {
      _packages = packages;
      _labels.clear();
      _labelsLoaded = false;
      _sizes.clear();
      _sizesLoaded = false;
    });
    await _loadLabels(packages);
    await _loadSizes(packages);
  }

  /// 应用名是每包一次平台调用；按 [getInstalledPackageLabels] 相同的批次限流，
  /// 避免几百个调用一次打满平台线程。
  Future<void> _loadLabels(List<PackageInfo> packages) async {
    const batchSize = 12;
    final names = [
      for (final p in packages)
        if (p.packageName != null) p.packageName!,
    ];
    for (var i = 0; i < names.length; i += batchSize) {
      final batch = names.sublist(
        i,
        i + batchSize > names.length ? names.length : i + batchSize,
      );
      await Future.wait(
        batch.map((name) async {
          try {
            final label = await packageManager.getApplicationLabel(
              packageName: name,
            );
            if (label != null && label.trim().isNotEmpty) {
              _labels[name] = label.trim();
            }
          } catch (_) {
            // 拿不到名称的包（如被隐藏的系统组件）就只显示包名。
          }
        }),
      );
      if (!mounted) return;
      setState(() {});
    }
    if (mounted) setState(() => _labelsLoaded = true);
  }

  /// 主 APK 大小也是每包一次文件系统调用（多数应用可读，APEX/受限包会抛错），
  /// 同样分批渐进加载；读不到的包不进表，排序时排在最后。
  Future<void> _loadSizes(List<PackageInfo> packages) async {
    const batchSize = 24;
    final targets = [
      for (final p in packages)
        if (p.packageName != null && p.applicationInfo?.sourceDir != null) p,
    ];
    for (var i = 0; i < targets.length; i += batchSize) {
      final batch = targets.sublist(
        i,
        i + batchSize > targets.length ? targets.length : i + batchSize,
      );
      await Future.wait(
        batch.map((p) async {
          try {
            final size = await File(p.applicationInfo!.sourceDir!).length();
            if (size > 0) _sizes[p.packageName!] = size;
          } catch (_) {}
        }),
      );
      if (!mounted) return;
      setState(() {});
    }
    if (mounted) setState(() => _sizesLoaded = true);
  }

  bool _isSystem(PackageInfo p) =>
      ((p.applicationInfo?.flags ?? 0) & _flagSystem) != 0 || p.isApex == true;

  String _displayName(PackageInfo p) =>
      _labels[p.packageName] ?? p.packageName ?? '?';

  bool _matchesQuery(PackageInfo p) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    final haystacks = [
      _displayName(p),
      p.packageName ?? '',
      p.versionName ?? '',
    ].map((e) => e.toLowerCase()).toList();
    return query
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .every((token) => haystacks.any((h) => h.contains(token)));
  }

  List<PackageInfo> get _visiblePackages {
    final packages = _packages;
    if (packages == null) return const [];
    final visible = packages.where((p) {
      final system = _isSystem(p);
      if (_filter == _TypeFilter.user && system) return false;
      if (_filter == _TypeFilter.system && !system) return false;
      return _matchesQuery(p);
    }).toList();
    // 用户应用排在系统应用前面；名称加载中按包名排（顺序稳定），全部加载完
    // 再按显示名重排一次。
    String key(PackageInfo p) => _labelsLoaded
        ? _displayName(p).toLowerCase()
        : p.packageName?.toLowerCase() ?? '';
    int compare(PackageInfo a, PackageInfo b) {
      switch (_sortMode) {
        case _SortMode.name:
          return key(a).compareTo(key(b));
        case _SortMode.updateTime:
          return (b.lastUpdateTime ?? 0).compareTo(a.lastUpdateTime ?? 0);
        case _SortMode.installTime:
          return (b.firstInstallTime ?? 0).compareTo(a.firstInstallTime ?? 0);
        case _SortMode.size:
          // 没读到大小的（还在加载/权限受限）排最后。
          final sizeCmp = (_sizes[a.packageName] ?? -1).compareTo(
            _sizes[b.packageName] ?? -1,
          );
          return sizeCmp != 0 ? -sizeCmp : key(a).compareTo(key(b));
      }
    }

    visible.sort((a, b) {
      final sys = (_isSystem(a) ? 1 : 0) - (_isSystem(b) ? 1 : 0);
      if (sys != 0) return sys;
      return compare(a, b);
    });
    return visible;
  }

  void _showDetails(PackageInfo info) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AppDetailSheet(
        info: info,
        displayName: _displayName(info),
        onUninstallStarted: (packageName) => _pendingRecheck = true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final packages = _packages;
    final userCount = packages?.where((p) => !_isSystem(p)).length ?? 0;
    final systemCount = (packages?.length ?? 0) - userCount;
    final visible = _visiblePackages;

    return Scaffold(
      backgroundColor: cs.surface,
      drawer: const ObtainAppDrawer(activePage: ObtainDrawerPage.allApps),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            CustomAppBar(
              title: '全部应用',
              actions: [
                PopupMenuButton<_SortMode>(
                  tooltip: '排序方式',
                  icon: const Icon(Icons.sort_rounded),
                  onSelected: (mode) => setState(() => _sortMode = mode),
                  itemBuilder: (context) => [
                    for (final mode in _SortMode.values)
                      CheckedPopupMenuItem(
                        value: mode,
                        checked: mode == _sortMode,
                        child: Text(_sortModeLabel(mode)),
                      ),
                  ],
                ),
              ],
              // 压栈路由默认给返回键，会盖掉抽屉按钮；页面切换统一走侧边栏，
              // 所以这里显式用汉堡按钮。
              leading: IconButton(
                icon: const Icon(Icons.menu),
                tooltip: '打开侧边栏',
                onPressed: () => Scaffold.maybeOf(context)?.openDrawer(),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      packages == null
                          ? '正在读取应用列表…'
                          : '共 ${packages.length} 个应用 · 用户 $userCount · 系统 $systemCount'
                              '${_labelsLoaded ? '' : ' · 正在读取应用名称…'}'
                              '${_sortMode == _SortMode.size && !_sizesLoaded ? ' · 正在读取大小…' : ''}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search),
                        hintText: '搜索名称 / 包名 / 版本',
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
                    const SizedBox(height: 12),
                    SegmentedButton<_TypeFilter>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: _TypeFilter.all,
                          label: Text('全部'),
                          icon: Icon(Icons.apps_rounded),
                        ),
                        ButtonSegment(
                          value: _TypeFilter.user,
                          label: Text('用户应用'),
                          icon: Icon(Icons.person_outline_rounded),
                        ),
                        ButtonSegment(
                          value: _TypeFilter.system,
                          label: Text('系统应用'),
                          icon: Icon(Icons.memory_rounded),
                        ),
                      ],
                      selected: {_filter},
                      onSelectionChanged: (selection) =>
                          setState(() => _filter = selection.first),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            if (packages == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (visible.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    '没有匹配的应用',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: visible.length,
                itemBuilder: (context, i) {
                  final info = visible[i];
                  return _AllAppTile(
                    key: ValueKey(info.packageName),
                    info: info,
                    displayName: _displayName(info),
                    isSystem: _isSystem(info),
                    sizeBytes: _sizes[info.packageName],
                    onTap: () => _showDetails(info),
                  );
                },
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}

/// 应用图标的按需加载 + 会话内缓存：ListView 只构建可见项，所以平台调用数量
/// 始终有界；详情面板复用同一份缓存。
final Map<String, Uint8List> _appIconCache = {};

class _PackageIcon extends StatefulWidget {
  const _PackageIcon({required this.packageName});

  final String packageName;

  @override
  State<_PackageIcon> createState() => _PackageIconState();
}

const double _iconSize = 40;

class _PackageIconState extends State<_PackageIcon> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _appIconCache[widget.packageName];
    if (_bytes == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final bytes = await packageManager.getApplicationIcon(
        packageName: widget.packageName,
      );
      if (bytes == null) return;
      _appIconCache[widget.packageName] = bytes;
      if (mounted) setState(() => _bytes = bytes);
    } catch (_) {
      // 没有图标的包保持占位图。
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return bytes != null
        ? Image.memory(bytes, width: _iconSize, height: _iconSize)
        : SizedBox(
            width: _iconSize,
            height: _iconSize,
            child: Icon(
              Icons.android_outlined,
              size: _iconSize * 0.7,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
  }
}

class _AllAppTile extends StatelessWidget {
  const _AllAppTile({
    super.key,
    required this.info,
    required this.displayName,
    required this.isSystem,
    required this.sizeBytes,
    required this.onTap,
  });

  final PackageInfo info;
  final String displayName;
  final bool isSystem;
  final int? sizeBytes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: _PackageIcon(packageName: info.packageName ?? ''),
      title: Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${info.packageName}\n'
        'v${info.versionName ?? '?'}'
        '${info.longVersionCode != null ? ' (${info.longVersionCode})' : ''}'
        '${sizeBytes != null ? ' · ${formatBytes(sizeBytes!)}' : ''}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      trailing: isSystem
          ? Tooltip(
              message: '系统应用',
              child: Icon(Icons.memory_rounded, color: cs.onSurfaceVariant),
            )
          : null,
      isThreeLine: true,
      onTap: onTap,
    );
  }
}

/// 与 AppsProvider.getStorageRootPath 相同的算法：从应用专属存储目录反推
/// 共享存储根（正常为 /storage/emulated/0），失败时退回最常见的路径。
Future<String> _storageRootPath() async {
  try {
    return '/${(await getAppStorageDir()).uri.pathSegments.sublist(0, 3).join('/')}';
  } catch (_) {
    return '/storage/emulated/0';
  }
}

String _safeFileName(String name) =>
    name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();

/// 把已安装应用的 APK 导出到 `Download/Obtainium`（「下载的 APK」页会列出该目录）。
///
/// 无 split 时直接复制主 APK；有 split 时打成 zip——只导出主 APK 对 split
/// 应用装不上（缺 density/ABI 配置），宁可打包也别产出半成品。split 与主 APK
/// 通常同目录，此时用 createFromFiles 免去中转拷贝；否则退回暂存目录。
Future<File> exportAppApk(PackageInfo info, String displayName) async {
  final appInfo = info.applicationInfo!;
  final sourceDir = appInfo.sourceDir;
  if (sourceDir == null) {
    throw Exception('该应用没有可读取的 APK 文件');
  }
  final destDirPath = '${await _storageRootPath()}/Download/Obtainium';
  await Directory(destDirPath).create(recursive: true);
  final baseName = _safeFileName(
    '$displayName-v${info.versionName ?? info.longVersionCode ?? '?'}',
  );
  final splits = appInfo.splitSourceDirs ?? const <String>[];
  if (splits.isEmpty) {
    final dest = File('$destDirPath/$baseName.apk');
    if (!dest.existsSync()) {
      await File(sourceDir).copy(dest.path);
    }
    return dest;
  }
  final files = <File>[File(sourceDir), for (final s in splits) File(s)];
  final dest = File('$destDirPath/$baseName-apks.zip');
  final parents = files.map((f) => f.parent.path).toSet();
  if (parents.length == 1) {
    await ZipFile.createFromFiles(
      sourceDir: files.first.parent,
      files: files,
      zipFile: dest,
    );
  } else {
    final staging = Directory(
      '${(await getTemporaryDirectory()).path}/apk-export/${info.packageName}',
    );
    if (staging.existsSync()) {
      staging.deleteSync(recursive: true);
    }
    await staging.create(recursive: true);
    for (final f in files) {
      await f.copy('${staging.path}/${f.path.split('/').last}');
    }
    try {
      await ZipFile.createFromDirectory(sourceDir: staging, zipFile: dest);
    } finally {
      try {
        staging.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
  return dest;
}

/// 单个应用的详细参数面板（底部弹层）。基础参数来自列表数据；权限与安装来源
/// 需要额外的平台调用，进面板后再异步补上。
class _AppDetailSheet extends StatefulWidget {
  const _AppDetailSheet({
    required this.info,
    required this.displayName,
    required this.onUninstallStarted,
  });

  final PackageInfo info;
  final String displayName;

  /// 发起系统卸载前回调（用于列表页在回到前台后自动重查）。
  final void Function(String packageName) onUninstallStarted;

  @override
  State<_AppDetailSheet> createState() => _AppDetailSheetState();
}

class _AppDetailSheetState extends State<_AppDetailSheet> {
  late final Future<(List<String>?, String?)> _extra;
  bool _exporting = false;

  ApplicationInfo get _appInfo => widget.info.applicationInfo!;

  bool get _isSystemApp =>
      ((_appInfo.flags & _flagSystem) != 0) || widget.info.isApex == true;

  @override
  void initState() {
    super.initState();
    _extra = _loadExtra();
  }

  Future<(List<String>?, String?)> _loadExtra() async {
    final packageName = widget.info.packageName;
    List<String>? permissions;
    String? installer;
    if (packageName != null) {
      try {
        final full = await packageManager.getPackageInfo(
          packageName: packageName,
          flags: PackageInfoFlags({PMFlag.getPermissions}),
        );
        permissions = full?.requestedPermissions;
      } catch (_) {}
      try {
        installer = await packageManager.getInstallerPackageName(
          packageName: packageName,
        );
      } catch (_) {}
    }
    return (permissions, installer);
  }

  void _copy(String value) {
    unawaited(copyToClipboard(context, value));
  }

  Future<void> _openApp() async {
    final packageName = widget.info.packageName;
    if (packageName == null) return;
    Navigator.of(context).pop();
    try {
      await packageManager.openApp(packageName);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开该应用')));
      }
    }
  }

  Future<void> _openSystemAppInfo() async {
    final packageName = widget.info.packageName;
    if (packageName == null) return;
    final intent = AndroidIntent(
      action: 'action_application_details_settings',
      data: 'package:$packageName',
    );
    try {
      await intent.launch();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开系统应用信息')));
      }
    }
  }

  Future<void> _exportApk() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final file = await exportAppApk(widget.info, widget.displayName);
      if (!mounted) return;
      final mimeType = file.path.toLowerCase().endsWith('.zip')
          ? 'application/zip'
          : 'application/vnd.android.package-archive';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出到 ${file.path}'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: '分享',
            onPressed: () => unawaited(
              SharePlus.instance.share(
                ShareParams(files: [XFile(file.path, mimeType: mimeType)]),
              ),
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) showMessage(e, context, isError: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _uninstall() async {
    final packageName = widget.info.packageName;
    if (packageName == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '卸载应用',
      content: Text(
        '确定要卸载 ${widget.displayName}（$packageName）吗？应用数据会一并删除。',
      ),
      confirmText: '卸载',
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop();
    widget.onUninstallStarted(packageName);
    // android_intent_plus 只原样透传未知 action，这里必须用完整常量。
    final intent = AndroidIntent(
      action: 'android.intent.action.DELETE',
      data: 'package:$packageName',
    );
    try {
      await intent.launch();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法启动系统卸载界面')));
      }
    }
  }

  String _sdkLabel(int? sdk) => sdk == null || sdk <= 0 ? '—' : 'API $sdk';

  String _formatTime(int? ms) =>
      ms == null || ms <= 0
          ? '—'
          : DateFormat(
              'yyyy-MM-dd HH:mm',
            ).format(DateTime.fromMillisecondsSinceEpoch(ms));

  String get _typeLabel {
    final flags = _appInfo.flags;
    final isApex = widget.info.isApex == true;
    return [
      if ((flags & _flagSystem) != 0 || isApex)
        isApex
            ? '系统应用（APEX）'
            : '系统应用'
      else
        '用户应用',
      if ((flags & _flagUpdatedSystemApp) != 0) '预装后已更新',
      if (!_appInfo.enabled) '已停用',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final appInfo = _appInfo;
    final valueStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
    );

    int? apkSize;
    final sourceDir = appInfo.sourceDir;
    if (sourceDir != null) {
      try {
        apkSize = File(sourceDir).lengthSync();
      } catch (_) {
        // 无法读取 APK 文件（权限受限）就不显示大小。
      }
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                _PackageIcon(packageName: widget.info.packageName ?? ''),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.displayName,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        widget.info.packageName ?? '—',
                        style: valueStyle?.copyWith(fontFamily: 'monospace'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _openApp,
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('打开应用'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _openSystemAppInfo,
                        icon: const Icon(Icons.settings_outlined, size: 16),
                        label: const Text('系统信息'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _exporting ? null : _exportApk,
                        icon: _exporting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save_alt_rounded, size: 16),
                        label: Text(_exporting ? '导出中…' : '导出 APK'),
                      ),
                    ),
                    if (!_isSystemApp) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _uninstall,
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 16,
                          ),
                          label: const Text('卸载'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 6,
                children: [
                  _paramRow('类型', _typeLabel, style: valueStyle),
                  _paramRow(
                    '版本',
                    'v${widget.info.versionName ?? '?'}'
                    '（versionCode ${widget.info.longVersionCode ?? widget.info.versionCode ?? '—'}）',
                    style: valueStyle,
                  ),
                  _paramRow(
                    'SDK',
                    '最低 ${_sdkLabel(appInfo.minSdkVersion)} · 目标 ${_sdkLabel(appInfo.targetSdkVersion)}'
                    '${appInfo.compileSdkVersion != null && appInfo.compileSdkVersion! > 0 ? ' · 编译 ${_sdkLabel(appInfo.compileSdkVersion)}${appInfo.compileSdkVersionCodename != null && appInfo.compileSdkVersionCodename!.isNotEmpty ? ' (${appInfo.compileSdkVersionCodename})' : ''}' : ''}',
                    style: valueStyle,
                  ),
                  _paramRow(
                    '时间',
                    '安装 ${_formatTime(widget.info.firstInstallTime)} · 更新 ${_formatTime(widget.info.lastUpdateTime)}',
                    style: valueStyle,
                  ),
                  _paramRow(
                    'APK',
                    apkSize != null
                        ? '${formatBytes(apkSize)} · $sourceDir'
                        : (sourceDir ?? '—'),
                    mono: true,
                    style: valueStyle,
                    onCopy: sourceDir == null
                        ? null
                        : () => _copy(sourceDir),
                  ),
                  if ((appInfo.splitSourceDirs?.length ?? 0) > 0)
                    _paramRow(
                      'Split',
                      '${appInfo.splitSourceDirs!.length} 个：${appInfo.splitSourceDirs!.join(', ')}',
                      mono: true,
                      style: valueStyle,
                    ),
                  if (appInfo.dataDir != null)
                    _paramRow(
                      '数据目录',
                      appInfo.dataDir!,
                      mono: true,
                      style: valueStyle,
                      onCopy: () => _copy(appInfo.dataDir!),
                    ),
                  _paramRow('UID', '${appInfo.uid}', style: valueStyle),
                  if (appInfo.processName != null)
                    _paramRow(
                      '进程名',
                      appInfo.processName!,
                      mono: true,
                      style: valueStyle,
                    ),
                  FutureBuilder<(List<String>?, String?)>(
                    future: _extra,
                    builder: (context, snapshot) {
                      final permissions = snapshot.hasData
                          ? snapshot.data!.$1
                          : null;
                      final installer = snapshot.hasData ? snapshot.data!.$2 : null;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 6,
                        children: [
                          _paramRow(
                            '安装来源',
                            installer ?? '未知（可能为 adb 或系统预装）',
                            mono: installer != null,
                            style: valueStyle,
                          ),
                          _permissionsSection(permissions, valueStyle),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _permissionsSection(
    List<String>? permissions,
    TextStyle? valueStyle,
  ) {
    if (permissions == null) {
      return _paramRow('权限', '读取中…', style: valueStyle);
    }
    if (permissions.isEmpty) {
      return _paramRow('权限', '未声明任何权限', style: valueStyle);
    }
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text('请求的权限（${permissions.length}）'),
      children: [
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 220),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final permission in permissions)
                  Text(
                    permission,
                    style: (valueStyle ?? const TextStyle(fontSize: 12))
                        .copyWith(fontFamily: 'monospace'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _paramRow(
    String label,
    String value, {
    bool mono = false,
    Color? valueColor,
    TextStyle? style,
    VoidCallback? onCopy,
  }) {
    var effectiveStyle = (style ?? const TextStyle(fontSize: 12)).copyWith(
      color: valueColor ?? style?.color,
    );
    if (mono) {
      effectiveStyle = effectiveStyle.copyWith(fontFamily: 'monospace');
    }
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
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (onCopy != null)
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
