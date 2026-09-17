import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/lan_transfer_service.dart';
import 'package:obtainium/utils/nav_helper.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

/// Shows a blocking dialog warning that an "include all settings" export
/// embeds potentially sensitive values in cleartext.
/// Returns true if the user chooses to export anyway.
Future<bool> confirmExportIncludesSecrets(BuildContext context) async {
  final proceed = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) {
      return AlertDialog(
        title: Text(tr('warning')),
        content: Text(tr('exportIncludesSecretsWarning')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('cancel')),
          ),
          FilledButton.tonal(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('continue')),
          ),
        ],
      );
    },
  );
  return proceed == true;
}

class ImportFromURLListPage extends StatefulWidget {
  const ImportFromURLListPage({super.key});

  @override
  State<ImportFromURLListPage> createState() => _ImportFromURLListPageState();
}

class _ImportFromURLListPageState extends State<ImportFromURLListPage> {
  late ImportFromURLListController _controller;
  final FocusNode _urlListFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    final sp = context.read<SourceProvider>();
    _controller = ImportFromURLListController(sourceProvider: sp);
  }

  @override
  void dispose() {
    _urlListFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _import() {
    final urls = _controller.getURLs();
    if (urls.isEmpty) return;
    final appsProvider = context.read<AppsProvider>();
    _controller.setImporting(true);
    appsProvider
        .addAppsByURL(urls)
        .then((errors) {
          if (!mounted) return;
          _controller.setImporting(false);
          if (errors.isEmpty) {
            showMessage(
              tr(
                'importedX',
                args: [plural('apps', urls.length).toLowerCase()],
              ),
              context,
            );
            Navigator.of(context).pop();
          } else {
            showDialog(
              context: context,
              builder: (BuildContext ctx) {
                return ImportErrorDialog(
                  urlsLength: urls.length,
                  errors: errors,
                );
              },
            );
          }
        })
        .catchError((e) {
          if (mounted) {
            _controller.setImporting(false);
            showError(e, context);
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _controller,
      child: Builder(
        builder: (context) {
          final controller = context.watch<ImportFromURLListController>();
          return Scaffold(
            backgroundColor: Theme.of(context).colorScheme.surface,
            body: CustomScrollView(
              slivers: [
                SliverAppBar(
                  pinned: true,
                  automaticallyImplyLeading: false,
                  title: Text(tr('importFromURLList')),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      MediaQuery.of(context).padding.bottom,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 16,
                      children: [
                        ConnectedCard(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          child: () {
                            final field = TextFormField(
                              focusNode: _urlListFocus,
                              controller: controller.urlController,
                              maxLines: null,
                              minLines: 8,
                              decoration: InputDecoration(
                                labelText: tr('appURLList'),
                              ),
                              validator: controller.validate,
                              autovalidateMode:
                                  AutovalidateMode.onUserInteraction,
                            );
                            return context.read<SettingsProvider>().isTV
                                ? TvTextFieldFocus(
                                    textFocusNode: _urlListFocus,
                                    borderRadius: 24,
                                    child: field,
                                  )
                                : field;
                          }(),
                        ),
                        OutlinedButton.icon(
                          onPressed: controller.isImporting
                              ? null
                              : () {
                                  context
                                      .read<SettingsProvider>()
                                      .selectionClick();
                                  controller.importFromFile(context);
                                },
                          icon: const Icon(Icons.upload_file_outlined),
                          label: Text(tr('importFromURLsInFile')),
                        ),
                        FilledButton(
                          onPressed: controller.isImporting
                              ? null
                              : () {
                                  context
                                      .read<SettingsProvider>()
                                      .selectionClick();
                                  _import();
                                },
                          child: controller.isImporting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(),
                                )
                              : Text(tr('import')),
                        ),
                        ConnectedCard(
                          isFirst: true,
                          isLast: true,
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            tr('importedAppsIdDisclaimer'),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontStyle: FontStyle.italic),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The app-import controls (file import, URL-list import, mass sources).
/// Embedded in the Settings → Import/Export page.
class ImportSection extends StatefulWidget {
  const ImportSection({super.key});

  @override
  State<ImportSection> createState() => _ImportSectionState();
}

class _ImportSectionState extends State<ImportSection> {
  bool importInProgress = false;

  Future<void> _runLanImport(BuildContext context) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => const LanImportDialog(),
    );
    if (result == null || !context.mounted) return;
    final appsProvider = context.read<AppsProvider>();
    final settingsProvider = context.read<SettingsProvider>();
    settingsProvider.selectionClick();
    try {
      jsonDecode(result);
    } catch (e) {
      if (!context.mounted) return;
      showError(ObtainiumError(tr('invalidInput')), context);
      return;
    }
    final conflictCount = appsProvider
        .appIdsInImportJSON(result)
        .where((id) => appsProvider.apps.containsKey(id))
        .length;
    if (conflictCount > 0 && context.mounted) {
      final proceed = await showConfirmDialog(
        context,
        title: tr('importX', args: [tr('appsString').toLowerCase()]),
        content: Text(
          tr('importOverwriteWarning', args: [conflictCount.toString()]),
        ),
        confirmText: tr('continue'),
      );
      if (!proceed) return;
    }
    setState(() => importInProgress = true);
    try {
      final value = await appsProvider.import(result);
      appsProvider.addMissingCategories(settingsProvider);
      if (!context.mounted) return;
      showMessage(
        '${tr('importedX', args: [plural('apps', value.key.length).toLowerCase()])}${value.value ? ' + ${tr('settings').toLowerCase()}' : ''}',
        context,
      );
    } catch (e) {
      if (context.mounted) showError(e, context);
    } finally {
      if (mounted) setState(() => importInProgress = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        if (importInProgress) const LinearProgressIndicator(),
        ConnectedCard(
          isFirst: true,
          isLast: false,
          child: ActionListTile(
            icon: Icons.download_outlined,
            label: tr('obtainiumImport'),
            onTap: importInProgress ? null : () => _runObtainiumImport(context),
          ),
        ),
        ConnectedCard(
          isFirst: false,
          isLast: true,
          child: ActionListTile(
            icon: Icons.wifi_outlined,
            label: tr('lanImportTitle'),
            onTap: importInProgress ? null : () => _runLanImport(context),
          ),
        ),
        Column(
          spacing: 2,
          children: () {
            final tiles = <Widget>[
              ActionListTile(
                icon: Icons.format_list_bulleted_outlined,
                label: tr('importFromURLList'),
                onTap: importInProgress
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          traversalEdgeBehavior: traversalEdgeBehaviorFor(
                            context,
                          ),
                          builder: (_) => const ImportFromURLListPage(),
                        ),
                      ),
              ),
              ...context.read<SourceProvider>().massUrlSources.map(
                (source) => ActionListTile(
                  icon: Icons.cloud_download_outlined,
                  label: tr('importX', args: [source.name]),
                  onTap: importInProgress
                      ? null
                      : () => _runMassSourceImport(context, source),
                ),
              ),
            ];
            return <Widget>[
              for (var i = 0; i < tiles.length; i++)
                ConnectedCard(
                  isFirst: i == 0,
                  isLast: i == tiles.length - 1,
                  child: tiles[i],
                ),
            ];
          }(),
        ),
      ],
    );
  }

  Future<void> _runObtainiumImport(BuildContext context) async {
    final appsProvider = context.read<AppsProvider>();
    final settingsProvider = context.read<SettingsProvider>();
    settingsProvider.selectionClick();
    final PlatformFile? file;
    try {
      file = await FilePicker.pickFile();
    } catch (e) {
      if (context.mounted) _showImportError(e, context);
      return;
    }
    if (file == null) {
      if (context.mounted) showMessage(tr('cancelled'), context);
      return;
    }
    if (mounted) {
      setState(() {
        importInProgress = true;
      });
    }
    try {
      final String data;
      if (file.path != null) {
        data = await File(file.path!).readAsString();
      } else {
        final bytesData = await file.readAsBytes();
        if (bytesData.isEmpty) {
          throw ObtainiumError(tr('noFilePickerAvailable'));
        }
        data = utf8.decode(bytesData);
      }
      try {
        jsonDecode(data);
      } catch (e) {
        throw ObtainiumError(tr('invalidInput'));
      }
      // Importing overwrites matching apps and applies the file's settings;
      // make that explicit before touching existing data.
      final conflictCount = appsProvider
          .appIdsInImportJSON(data)
          .where((id) => appsProvider.apps.containsKey(id))
          .length;
      if (conflictCount > 0) {
        if (!context.mounted) return;
        final proceed = await showConfirmDialog(
          context,
          title: tr('importX', args: [tr('appsString').toLowerCase()]),
          content: Text(
            tr('importOverwriteWarning', args: [conflictCount.toString()]),
          ),
          confirmText: tr('continue'),
        );
        if (!proceed) return;
      }
      final value = await appsProvider.import(data);
      appsProvider.addMissingCategories(settingsProvider);
      if (!context.mounted) return;
      showMessage(
        '${tr('importedX', args: [plural('apps', value.key.length).toLowerCase()])}${value.value ? ' + ${tr('settings').toLowerCase()}' : ''}',
        context,
      );
    } catch (e) {
      if (context.mounted) _showImportError(e, context);
    } finally {
      if (mounted) {
        setState(() {
          importInProgress = false;
        });
      }
    }
  }

  Future<void> _runMassSourceImport(
    BuildContext context,
    MassAppUrlSource source,
  ) async {
    final appsProvider = context.read<AppsProvider>();
    try {
      final values = await showDialog<Map<String, dynamic>?>(
        context: context,
        builder: (BuildContext ctx) {
          return GeneratedFormModal(
            title: tr('importX', args: [source.name]),
            items: source.requiredArgs
                .map((e) => [GeneratedFormTextField(e, label: e)])
                .toList(),
          );
        },
      );
      if (values != null) {
        if (mounted) {
          setState(() {
            importInProgress = true;
          });
        }
        final urlsWithDescriptions = await source.getUrlsWithDescriptions(
          values.values.map((e) => e.toString()).toList(),
        );
        if (!context.mounted) return;
        final selectedUrls = await showDialog<List<String>?>(
          context: context,
          builder: (BuildContext ctx) {
            return SelectionModal(entries: urlsWithDescriptions);
          },
        );
        if (selectedUrls != null) {
          final errors = await appsProvider.addAppsByURL(selectedUrls);
          if (!context.mounted) return;
          if (errors.isEmpty) {
            showMessage(
              tr(
                'importedX',
                args: [plural('apps', selectedUrls.length).toLowerCase()],
              ),
              context,
            );
          } else {
            unawaited(
              showDialog(
                context: context,
                builder: (BuildContext ctx) {
                  return ImportErrorDialog(
                    urlsLength: selectedUrls.length,
                    errors: errors,
                  );
                },
              ),
            );
          }
        }
      }
    } catch (e) {
      if (context.mounted) showError(e, context);
    } finally {
      if (mounted) {
        setState(() {
          importInProgress = false;
        });
      }
    }
  }
}

/// The app-export controls (export dir picker, export action, auto-export and
/// settings-inclusion options). Embedded in the Settings → Import/Export page.
class ExportSection extends StatefulWidget {
  const ExportSection({super.key});

  @override
  State<ExportSection> createState() => _ExportSectionState();
}

class _ExportSectionState extends State<ExportSection> {
  Future<Uri?>? _exportDirFuture;
  String? _lastExportDirKey;
  bool exportInProgress = false;
  final FocusNode _fileNameFocus = FocusNode();

  @override
  void dispose() {
    _fileNameFocus.dispose();
    super.dispose();
  }

  Future<void> _startLanShare() async {
    final appsProvider = context.read<AppsProvider>();
    final settingsProvider = context.read<SettingsProvider>();
    settingsProvider.selectionClick();
    if (settingsProvider.exportSettings >= 2) {
      final proceed = await confirmExportIncludesSecrets(context);
      if (!proceed) return;
    }
    final hasLan = await hasLanConnection();
    if (!hasLan && context.mounted) {
      showError(ObtainiumError(tr('lanShareNotAvailable')), context);
      return;
    }
    final jsonMap = appsProvider.generateExportJSON();
    final jsonString = jsonEncode(jsonMap);
    try {
      final info = await LanTransferService.start(
        jsonPayload: jsonString,
        fileName: '${settingsProvider.autoExportFileName ?? 'obtainium-export'}.json',
      );
      if (!mounted) {
        await info.service.stop();
        return;
      }
      await showDialog(
        context: context,
        builder: (_) => LanExportDialog(info: info),
      );
      await info.service.stop();
    } catch (e) {
      if (context.mounted) showError(e, context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appsProvider = context.read<AppsProvider>();
    final settingsProvider = context.watch<SettingsProvider>();

    final exportDirKey = settingsProvider.prefs?.getString('exportDir');
    if (_exportDirFuture == null || exportDirKey != _lastExportDirKey) {
      _lastExportDirKey = exportDirKey;
      _exportDirFuture = settingsProvider.getExportDir();
    }

    Future<void> runObtainiumExport({bool pickOnly = false}) async {
      if (exportInProgress) return;
      settingsProvider.selectionClick();
      if (!pickOnly && settingsProvider.exportSettings >= 2) {
        final proceed = await confirmExportIncludesSecrets(context);
        if (!proceed) return;
      }
      setState(() => exportInProgress = true);
      try {
        final result = await appsProvider.export(
          pickOnly: pickOnly || (await settingsProvider.getExportDir()) == null,
          sp: settingsProvider,
        );
        if (result != null && context.mounted) {
          showMessage(tr('exportedTo', args: [result]), context);
        }
      } catch (e) {
        if (context.mounted) showError(e, context);
      } finally {
        if (mounted) {
          setState(() => exportInProgress = false);
        }
      }
    }

    return FutureBuilder(
      future: _exportDirFuture,
      builder: (context, snapshot) {
        final items = <Widget>[
          if (exportInProgress) const LinearProgressIndicator(),
          ConnectedCard(
            isFirst: true,
            isLast: false,
            child: ActionListTile(
              icon: Icons.folder_open_outlined,
              label: tr('pickExportDir'),
              trailing: snapshot.data != null
                  ? Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: exportInProgress
                  ? null
                  : () => runObtainiumExport(pickOnly: true),
            ),
          ),
          ConnectedCard(
            isFirst: false,
            isLast: false,
            child: ActionListTile(
              icon: Icons.upload_outlined,
              label: tr('obtainiumExport'),
              onTap: snapshot.data == null || exportInProgress
                  ? null
                  : runObtainiumExport,
            ),
          ),
          ConnectedCard(
            isFirst: false,
            isLast: snapshot.data == null,
            child: ActionListTile(
              icon: Icons.wifi_outlined,
              label: tr('lanTransfer'),
              onTap: exportInProgress ? null : _startLanShare,
            ),
          ),
        ];
        if (snapshot.data != null) {
          items.addAll([
            ConnectedCard(
              isFirst: false,
              isLast: false,
              child: ToggleTile(
                label: tr('autoExportOnChanges'),
                value: settingsProvider.autoExportOnChanges,
                onChanged: (value) =>
                    settingsProvider.autoExportOnChanges = value,
              ),
            ),
            ConnectedCard(
              isFirst: false,
              isLast: false,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: () {
                final field = TextFormField(
                  focusNode: _fileNameFocus,
                  initialValue: settingsProvider.autoExportFileName ?? '',
                  decoration: InputDecoration(
                    labelText: tr('autoExportFileName'),
                    hintText: tr('obtainiumExportHyphenatedLowercase'),
                    border: InputBorder.none,
                  ),
                  onChanged: (value) =>
                      settingsProvider.autoExportFileName = value,
                );
                return settingsProvider.isTV
                    ? TvTextFieldFocus(
                        textFocusNode: _fileNameFocus,
                        borderRadius: 16,
                        child: field,
                      )
                    : field;
              }(),
            ),
            ConnectedCard(
              isFirst: false,
              isLast: false,
              child: ToggleTile(
                label: tr('exportInstalledOnly'),
                value: settingsProvider.exportInstalledOnly,
                onChanged: (value) =>
                    settingsProvider.exportInstalledOnly = value,
              ),
            ),
            ConnectedCard(
              isFirst: false,
              isLast: true,
              child: TvDropdownMenu<String>(
                expandedInsets: EdgeInsets.zero,
                label: Text(tr('includeSettings')),
                initialSelection: settingsProvider.exportSettings.toString(),
                dropdownMenuEntries: [
                  DropdownMenuEntry(value: '0', label: tr('none')),
                  DropdownMenuEntry(value: '1', label: tr('excludeSecrets')),
                  DropdownMenuEntry(value: '2', label: tr('all')),
                ],
                onSelected: (value) {
                  if (value != null) {
                    settingsProvider.exportSettings = int.tryParse(value) ?? 1;
                  }
                },
              ),
            ),
          ]);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 3,
          children: items,
        );
      },
    );
  }
}

/// Dialog shown on the sending side while a LAN transfer is active.
/// Displays a QR code and a plain URL so the receiver can fetch the JSON.
class LanExportDialog extends StatelessWidget {
  final LanShareInfo info;
  const LanExportDialog({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('lanExportTitle')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('lanExportRunning')),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: info.url,
                version: QrVersions.auto,
                size: 200,
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                errorStateBuilder: (cxt, err) {
                  return const Center(
                    child: Icon(Icons.error_outline),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: info.url));
                showMessage(tr('copiedToClipboard'), context);
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  info.url,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            if (info.lanIp == null) ...[
              const SizedBox(height: 8),
              Text(
                tr('lanShareNotAvailable'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton.tonal(
          onPressed: () => Navigator.of(context).pop(),
          autofocus: true,
          child: Text(tr('lanExportStop')),
        ),
      ],
    );
  }
}

/// Dialog shown on the receiving side — enter the URL displayed by the sender
/// and import the JSON directly without touching the file system.
class LanImportDialog extends StatefulWidget {
  const LanImportDialog({super.key});

  @override
  State<LanImportDialog> createState() => _LanImportDialogState();
}

class _LanImportDialogState extends State<LanImportDialog> {
  final TextEditingController _urlController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = tr('invalidInput'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final jsonString = await fetchJsonFromUrl(url);
      if (!mounted) return;
      Navigator.of(context).pop(jsonString);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('lanImportTitle')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('lanImportUrlHint')),
            const SizedBox(height: 12),
            TextFormField(
              controller: _urlController,
              decoration: InputDecoration(
                labelText: tr('lanImportConnect'),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  tooltip: tr('lanScanQr'),
                  onPressed: _loading ? null : _openScanner,
                ),
              ),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onFieldSubmitted: (_) => _connect(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: Text(tr('cancel')),
        ),
        FilledButton(
          onPressed: _loading ? null : _connect,
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('lanImportConnectBtn')),
        ),
      ],
    );
  }

  /// Request camera permission, then open a full-screen scanner page.
  /// On success, the scanned URL is pre-filled in the text field and the
  /// import is triggered automatically.
  Future<void> _openScanner() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (!status.isGranted) {
      showError(
        ObtainiumError(tr('lanCameraPermissionRequired')),
        context,
      );
      return;
    }
    final scannedUrl = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _QrScannerPage()),
    );
    if (scannedUrl == null || !mounted) return;
    setState(() {
      _urlController.text = scannedUrl;
      _error = null;
    });
    // Auto-connect when a URL is scanned
    _connect();
  }
}

/// Full-screen QR scanner used when the receiver taps the scan button
/// in [LanImportDialog]. Returns the decoded URL string on success.
class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw != null && raw.isNotEmpty) {
        final uri = Uri.tryParse(raw);
        if (uri != null && uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https')) {
          _handled = true;
          Navigator.of(context).pop(raw);
          return;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('lanScanQr'))),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          Center(
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  tr('lanScanHint'),
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ImportErrorDialog extends StatelessWidget {
  const ImportErrorDialog({
    super.key,
    required this.urlsLength,
    required this.errors,
  });

  final int urlsLength;
  final List<List<String>> errors;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(tr('importErrors')),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(
              'importedXOfYApps',
              args: [
                (urlsLength - errors.length).toString(),
                urlsLength.toString(),
              ],
            ),
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          Text(
            tr('followingURLsHadErrors'),
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          ...errors.map((e) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16),
                Text(e[0]),
                Text(e[1], style: const TextStyle(fontStyle: FontStyle.italic)),
              ],
            );
          }),
        ],
      ),
      actions: [
        FilledButton.tonal(
          autofocus: context.read<SettingsProvider>().isTV,
          onPressed: () {
            Navigator.of(context).pop(null);
          },
          child: Text(tr('ok')),
        ),
      ],
    );
  }
}

class SelectionModal extends StatefulWidget {
  const SelectionModal({
    super.key,
    required this.entries,
    this.selectedByDefault = true,
    this.onlyOneSelectionAllowed = false,
    this.titlesAreLinks = true,
    this.title,
    this.deselectThese = const [],
  });

  final String? title;
  final Map<String, List<String>> entries;
  final bool selectedByDefault;
  final List<String> deselectThese;
  final bool onlyOneSelectionAllowed;
  final bool titlesAreLinks;

  @override
  State<SelectionModal> createState() => _SelectionModalState();
}

class _SelectionModalState extends State<SelectionModal> {
  /// Selection state keyed by entry URL.
  Map<String, bool> entrySelections = {};
  String filterRegex = '';
  @override
  void didUpdateWidget(SelectionModal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entries != oldWidget.entries ||
        widget.selectedByDefault != oldWidget.selectedByDefault ||
        widget.deselectThese != oldWidget.deselectThese) {
      _resetEntrySelections();
    }
  }

  @override
  void initState() {
    super.initState();
    _resetEntrySelections();
  }

  void selectOnlyOne(String url) {
    for (var key in entrySelections.keys) {
      entrySelections[key] = key == url;
    }
  }

  void selectAll({bool deselect = false, Iterable<String>? visible}) {
    context.read<SettingsProvider>().selectionClick();
    for (var key in visible ?? entrySelections.keys) {
      entrySelections[key] = !deselect;
    }
  }

  void _resetEntrySelections() {
    entrySelections.clear();
    for (var entry in widget.entries.entries) {
      entrySelections[entry.key] =
          widget.selectedByDefault &&
          !widget.onlyOneSelectionAllowed &&
          !widget.deselectThese.contains(entry.key);
    }
    if (widget.selectedByDefault &&
        widget.onlyOneSelectionAllowed &&
        widget.entries.entries.isNotEmpty) {
      selectOnlyOne(widget.entries.entries.first.key);
    }
  }

  Widget _buildSelectAllButton(
    List<MapEntry<String, List<String>>> visibleEntries,
  ) {
    if (widget.onlyOneSelectionAllowed) {
      return const SizedBox.shrink();
    }
    // Operate on what the user can actually see, so tapping Select all while
    // a filter is active doesn't silently select hidden entries.
    final visibleUrls = visibleEntries.map((e) => e.key).toList();
    final visibleSelected = visibleUrls
        .where((url) => entrySelections[url] == true)
        .length;
    return visibleSelected == 0
        ? TextButton(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onPressed: () {
              setState(() {
                selectAll(visible: visibleUrls);
              });
            },
            child: Text(tr('selectAll'), overflow: TextOverflow.ellipsis),
          )
        : TextButton(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onPressed: () {
              setState(() {
                selectAll(deselect: true, visible: visibleUrls);
              });
            },
            child: Text(
              tr('deselectX', args: [visibleSelected.toString()]),
              overflow: TextOverflow.ellipsis,
            ),
          );
  }

  void _selectThis(String url, bool? value) {
    context.read<SettingsProvider>().selectionClick();
    setState(() {
      value ??= false;
      if (value! && widget.onlyOneSelectionAllowed) {
        selectOnlyOne(url);
      } else {
        entrySelections[url] = value!;
      }
    });
  }

  Widget _buildUrlLink(MapEntry<String, List<String>> entry) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.titlesAreLinks)
          LinkText(
            text: entry.value.isEmpty ? entry.key : entry.value[0],
            url: entry.key,
            style: const TextStyle(fontWeight: FontWeight.bold),
          )
        else
          Text(
            entry.value.isEmpty ? entry.key : entry.value[0],
            style: const TextStyle(fontWeight: FontWeight.bold),
            textAlign: TextAlign.start,
          ),
        if (widget.titlesAreLinks)
          Text(
            Uri.parse(entry.key).host,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              decoration: TextDecoration.underline,
            ),
          ),
      ],
    );
  }

  Widget _buildDescriptionText(MapEntry<String, List<String>> entry) {
    return entry.value.length <= 1
        ? const SizedBox.shrink()
        : Text(
            entry.value[1].length > 128
                ? '${entry.value[1].substring(0, 128)}...'
                : entry.value[1],
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          );
  }

  Widget _buildSingleSelectTile(MapEntry<String, List<String>> entry) {
    return ListTile(
      title: InkWell(
        onTap: widget.titlesAreLinks
            ? null
            : () {
                _selectThis(entry.key, !(entrySelections[entry.key] ?? false));
              },
        child: _buildUrlLink(entry),
      ),
      subtitle: entry.value.length <= 1
          ? null
          : InkWell(
              onTap: () {
                setState(() {
                  selectOnlyOne(entry.key);
                });
              },
              child: _buildDescriptionText(entry),
            ),
      leading: Radio<String>(value: entry.key),
    );
  }

  Widget _buildMultiSelectTile(MapEntry<String, List<String>> entry) {
    return Row(
      children: [
        Checkbox(
          value: entrySelections[entry.key],
          onChanged: (value) {
            _selectThis(entry.key, value);
          },
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 8),
              InkWell(
                onTap: widget.titlesAreLinks
                    ? null
                    : () {
                        _selectThis(
                          entry.key,
                          !(entrySelections[entry.key] ?? false),
                        );
                      },
                child: _buildUrlLink(entry),
              ),
              entry.value.length <= 1
                  ? const SizedBox.shrink()
                  : InkWell(
                      onTap: () {
                        _selectThis(
                          entry.key,
                          !(entrySelections[entry.key] ?? false),
                        );
                      },
                      child: _buildDescriptionText(entry),
                    ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ],
    );
  }

  /// TV variant: the whole row is a single focus stop; the checkbox/radio is
  /// painted but never focused. D-pad users toggle by pressing the center
  /// button on the row instead of having to land on a small control.
  Widget _buildTVSelectTile(MapEntry<String, List<String>> entry) {
    final selected = entrySelections[entry.key] ?? false;
    return TvFocusRing(
      borderRadius: 16,
      child: ListTile(
        leading: ExcludeFocus(
          child: widget.onlyOneSelectionAllowed
              ? Radio<String>(value: entry.key)
              : Checkbox(value: selected, onChanged: null),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.value.isEmpty ? entry.key : entry.value[0],
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (widget.titlesAreLinks)
              Text(
                Uri.parse(entry.key).host,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  decoration: TextDecoration.underline,
                ),
              ),
          ],
        ),
        subtitle: entry.value.length <= 1 ? null : _buildDescriptionText(entry),
        selected: selected,
        onTap: () {
          context.read<SettingsProvider>().selectionClick();
          if (widget.onlyOneSelectionAllowed) {
            Navigator.of(context).pop([entry.key]);
          } else {
            _selectThis(entry.key, !selected);
          }
        },
      ),
    );
  }

  List<Widget> _buildTVFooter() {
    if (!context.read<SettingsProvider>().isTV ||
        widget.onlyOneSelectionAllowed) {
      return [];
    }
    return [
      const SizedBox(height: 8),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('cancel')),
          ),
          TextButton(
            onPressed: entrySelections.values.where((b) => b).isEmpty
                ? null
                : () => Navigator.of(context).pop(
                    entrySelections.entries
                        .where((entry) => entry.value)
                        .map((e) => e.key)
                        .toList(),
                  ),
            child: Text(
              tr(
                'selectX',
                args: [
                  entrySelections.values.where((b) => b).length.toString(),
                ],
              ),
            ),
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isTV = context.read<SettingsProvider>().isTV;
    final filterRegexCompiled = filterRegex.isEmpty
        ? null
        : RegExp(filterRegex);
    final List<MapEntry<String, List<String>>> filteredEntries = [];
    String searchableText(MapEntry<String, List<String>> entry) =>
        entry.value.isEmpty ? entry.key : entry.value[0];
    for (final entry in widget.entries.entries) {
      if (filterRegexCompiled == null ||
          filterRegexCompiled.hasMatch(searchableText(entry))) {
        filteredEntries.add(entry);
      }
    }
    if (filterRegex.isNotEmpty && filteredEntries.isEmpty) {
      final filterRegexCompiledCI = RegExp(filterRegex, caseSensitive: false);
      for (final entry in widget.entries.entries) {
        if (filterRegexCompiledCI.hasMatch(searchableText(entry))) {
          filteredEntries.add(entry);
        }
      }
    }

    final selectedRadioKey = entrySelections.entries
        .where((e) => e.value)
        .map((e) => e.key)
        .firstOrNull;
    void onRadioChanged(String? value) {
      if (value == null) return;
      context.read<SettingsProvider>().selectionClick();
      if (isTV) {
        Navigator.of(context).pop([value]);
      } else {
        setState(() {
          selectOnlyOne(value);
        });
      }
    }

    return AlertDialog(
      scrollable: true,
      title: Text(widget.title ?? tr('pick')),
      content: RadioGroup<String>(
        groupValue: selectedRadioKey,
        onChanged: onRadioChanged,
        child: Column(
          children: [
            GeneratedForm(
              tileMode: true,
              noTilePadding: true,
              items: [
                [
                  GeneratedFormTextField(
                    'filter',
                    label: tr('filter'),
                    required: false,
                    additionalValidators: [
                      (value) {
                        return regExValidator(value);
                      },
                    ],
                  ),
                ],
              ],
              onValueChanges: (value, valid, isBuilding) {
                if (valid && !isBuilding) {
                  if (value['filter'] != null) {
                    setState(() {
                      filterRegex = value['filter'];
                    });
                  }
                }
              },
            ),
            ...filteredEntries.map((entry) {
              if (isTV) return _buildTVSelectTile(entry);
              return widget.onlyOneSelectionAllowed
                  ? _buildSingleSelectTile(entry)
                  : _buildMultiSelectTile(entry);
            }),
            ..._buildTVFooter(),
          ],
        ),
      ),
      // A single flexible row keeps the select-all count from pushing the
      // actions into AlertDialog's vertical overflow layout. The label
      // ellipsizes on very narrow screens instead.
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      actions: [
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: _buildSelectAllButton(filteredEntries),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              autofocus: isTV,
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text(tr('cancel')),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: entrySelections.values.where((b) => b).isEmpty
                  ? null
                  : () {
                      Navigator.of(context).pop(
                        entrySelections.entries
                            .where((entry) => entry.value)
                            .map((e) => e.key)
                            .toList(),
                      );
                    },
              child: Text(
                widget.onlyOneSelectionAllowed
                    ? tr('pick')
                    : tr(
                        'selectX',
                        args: [
                          entrySelections.values
                              .where((b) => b)
                              .length
                              .toString(),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

void _showImportError(dynamic e, BuildContext context) {
  if (e is PlatformException || e is MissingPluginException) {
    showError(ObtainiumError(tr('noFilePickerAvailable')), context);
  } else {
    showError(e, context);
  }
}

class ImportFromURLListController extends ChangeNotifier {
  final TextEditingController urlController = TextEditingController();
  bool isImporting = false;

  final SourceProvider sourceProvider;

  ImportFromURLListController({SourceProvider? sourceProvider})
    : sourceProvider = sourceProvider ?? SourceProvider();

  Future<void> importFromFile(BuildContext context) async {
    try {
      final file = await FilePicker.pickFile();
      if (file == null) return;
      final String contents;
      if (file.path != null) {
        contents = await File(file.path!).readAsString();
      } else {
        // Some pickers only expose bytes; an empty result is a bad file, not
        // a missing picker.
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          throw ObtainiumError(tr('invalidInput'));
        }
        contents = utf8.decode(bytes);
      }
      final urls = RegExp(r'https?://[^\s"]+')
          .allMatches(contents)
          .map((e) => e.input.substring(e.start, e.end))
          .toSet()
          .toList()
          .where((url) {
            try {
              sourceProvider.getSource(url);
              return true;
            } catch (e) {
              AppLogger.error(e, message: 'URL parse error in filter');
              return false;
            }
          })
          .join('\n');
      urlController.text = urls;
      notifyListeners();
    } catch (e) {
      if (context.mounted) {
        _showImportError(e, context);
      }
    }
  }

  String? validate(String? value) {
    if (value != null && value.isNotEmpty) {
      final lines = value.split('\n');
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        try {
          sourceProvider.getSource(line);
        } catch (e) {
          return '${tr('line')} ${i + 1}: $e';
        }
      }
    }
    return null;
  }

  List<String> getURLs() {
    return urlController.text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  void setImporting(bool v) {
    isImporting = v;
    notifyListeners();
  }

  @override
  void dispose() {
    urlController.dispose();
    super.dispose();
  }
}
