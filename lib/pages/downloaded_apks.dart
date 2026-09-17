import 'dart:async';
import 'dart:io';

import 'package:android_package_installer/android_package_installer.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/installers/installer.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:provider/provider.dart';

/// Lists APK files kept from downloads (install cache + the public
/// Download/Obtainium folder) so the user can reinstall or delete them
/// without re-downloading after a failed or cancelled install.
class DownloadedApksPage extends StatefulWidget {
  const DownloadedApksPage({super.key});

  @override
  State<DownloadedApksPage> createState() => _DownloadedApksPageState();
}

class _DownloadedApksPageState extends State<DownloadedApksPage> {
  List<File> files = [];
  bool loading = true;
  bool installing = false;

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
  }

  Future<void> refresh() async {
    setState(() => loading = true);
    final dirs = <Directory>[];
    try {
      final appsProvider = context.read<AppsProvider>();
      dirs.add(appsProvider.apkDir);
    } catch (e) {
      AppLogger.info('Download cache not available yet: ${e.toString()}');
    }
    final kept = Directory('/storage/emulated/0/Download/Obtainium');
    if (kept.existsSync()) dirs.add(kept);
    final found = <File>[];
    for (final d in dirs) {
      if (!d.existsSync()) continue;
      for (final e in d.listSync()) {
        if (e is File && e.path.toLowerCase().endsWith('.apk')) {
          found.add(e);
        }
      }
    }
    // Newest first; tolerate files disappearing mid-listing.
    found.removeWhere((f) => !f.existsSync());
    found.sort((a, b) {
      try {
        return b.lastModifiedSync().compareTo(a.lastModifiedSync());
      } catch (e) {
        return a.path.compareTo(b.path);
      }
    });
    if (mounted) {
      setState(() {
        files = found;
        loading = false;
      });
    }
  }

  /// Installs via the system package installer and surfaces the concrete
  /// outcome (success / readable error / cancelled) as a toast.
  Future<void> installApkFile(File f) async {
    if (installing) return;
    setState(() => installing = true);
    try {
      final code = await AndroidPackageInstaller.installApk(
        apkFilePath: f.path,
      );
      final result = InstallResult.fromPlatformCode(code);
      if (!mounted) return;
      final msg = result.isSuccess
          ? tr('installed')
          : result.isError
          ? installErrorCodeToMessage(result.errorCode ?? -1)
          : tr('installCancelled');
      unawaited(
        Fluttertoast.showToast(msg: msg, toastLength: Toast.LENGTH_LONG),
      );
    } catch (e) {
      if (mounted) {
        showMessage(e, context, isError: true);
      }
    } finally {
      installing = false;
      unawaited(refresh());
    }
  }

  Future<void> deleteApkFile(File f) async {
    final confirmed = await showConfirmDialog(
      context,
      title: tr('delete'),
      content: Text('${tr('delete')}? ${f.path.split('/').last}'),
      confirmText: tr('delete'),
    );
    if (!confirmed) return;
    try {
      f.deleteSync();
    } catch (e) {
      if (mounted) showMessage(e, context, isError: true);
    }
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('downloadedApks')),
        actions: [
          IconButton(
            tooltip: tr('refresh'),
            onPressed: loading ? null : refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : files.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.download_for_offline_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      tr('downloadedApksEmpty'),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr('downloadedApksHelp'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: refresh,
              child: ListView.builder(
                itemCount: files.length,
                itemBuilder: (context, i) {
                  final f = files[i];
                  String subtitle;
                  try {
                    final sizeMb = (f.lengthSync() / 1048576).toStringAsFixed(1);
                    final modified = f.lastModifiedSync().toLocal();
                    final dateStr = modified
                        .toIso8601String()
                        .substring(0, 16)
                        .replaceAll('T', ' ');
                    final dirName = f.parent.path.split('/').last;
                    subtitle = '$sizeMb MB · $dateStr · $dirName';
                  } catch (e) {
                    subtitle = f.path;
                  }
                  return ListTile(
                    leading: const Icon(Icons.android_outlined),
                    title: Text(
                      f.path.split('/').last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(subtitle),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: tr('installed'),
                          onPressed:
                              installing ? null : () => installApkFile(f),
                          icon: const Icon(Icons.install_mobile),
                        ),
                        IconButton(
                          tooltip: tr('delete'),
                          onPressed: () => deleteApkFile(f),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                    onTap: installing ? null : () => installApkFile(f),
                  );
                },
              ),
            ),
    );
  }
}
