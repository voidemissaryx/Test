import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_symbols_icons/symbols.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/settings.dart';
import '../services/chain_proxy.dart';
import '../services/vpn_channel.dart';
import '../state/app_state.dart';

/// The V2rayNG section manages share links supported by this app's existing Xray parser.
/// Imported entries are available as chain proxies; this page does not add a second VPN engine.
class V2rayNgPage extends StatefulWidget {
  const V2rayNgPage({super.key});

  @override
  State<V2rayNgPage> createState() => _V2rayNgPageState();
}

class _V2rayNgPageState extends State<V2rayNgPage> {
  final _search = TextEditingController();
  final Set<String> _selected = {};
  bool _selecting = false;
  String _category = 'All';
  final Map<String, int> _latencies = {};
  final Set<String> _probing = {};

  Future<void> _probe(ChainProxy config) async {
    final info = ChainInfo.of(config.link);
    if (info == null) { _message('This configuration is invalid.'); return; }
    if (info.isUdp) { _message('A TCP ping is not valid for this UDP-only endpoint.'); return; }
    setState(() => _probing.add(config.id));
    try {
      final watch = Stopwatch()..start();
      final socket = await Socket.connect(info.uri.server, info.uri.port, timeout: const Duration(seconds: 4));
      watch.stop();
      socket.destroy();
      if (mounted) setState(() => _latencies[config.id] = watch.elapsedMilliseconds);
      _message('${config.name}: ${watch.elapsedMilliseconds} ms TCP latency');
    } catch (e) {
      _message('${config.name}: endpoint is not reachable over TCP.');
    } finally {
      if (mounted) setState(() => _probing.remove(config.id));
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  String _decodeSubscription(String text) {
    final trimmed = text.trim();
    try {
      parseChainProxies(trimmed);
      return trimmed;
    } on FormatException {
      // A number of subscription endpoints return base64-encoded share links.
    }
    final compact = trimmed.replaceAll(RegExp(r'\s+'), '');
    try {
      final normalized = base64Url.normalize(compact);
      final decoded = utf8.decode(base64Url.decode(normalized));
      parseChainProxies(decoded);
      return decoded;
    } catch (_) {
      throw const FormatException('The subscription does not contain supported share links.');
    }
  }

  void _importText(String? text, {String? fileName, String? category}) {
    if (text == null || text.trim().isEmpty) {
      _message('No configuration data was provided.');
      return;
    }
    try {
      final parsed = parseChainProxies(_decodeSubscription(text), fileName: fileName);
      final configs = [
        for (final item in parsed)
          ChainProxy(
            id: item.id,
            name: item.name,
            link: item.link,
            category: category,
          ),
      ];
      final state = AppScope.read(context);
      final before = state.profile.chains.length;
      state.addChains(configs);
      final added = state.profile.chains.length - before;
      _message(added == 0 ? 'These configurations are already imported.' : 'Imported $added configuration(s).');
    } on FormatException catch (e) {
      _message(e.message);
    } catch (e) {
      _message('Import failed: $e');
    }
  }

  Future<void> _manualImport() async {
    final controller = TextEditingController();
    final categoryController = TextEditingController();
    final result = await showDialog<({String text, String category})>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add manually'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                minLines: 4,
                maxLines: 8,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Configuration link or WireGuard config',
                  hintText: 'vless://… or vmess://…',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: categoryController,
                decoration: const InputDecoration(labelText: 'Category (optional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              (text: controller.text, category: categoryController.text.trim()),
            ),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    controller.dispose();
    categoryController.dispose();
    if (result != null) _importText(result.text, category: result.category.isEmpty ? null : result.category);
  }

  Future<void> _importClipboard() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    _importText(text);
  }

  Future<void> _importFile() async {
    try {
      final file = await VpnChannel.pickFile();
      if (file != null) _importText(file.content, fileName: file.name);
    } on PlatformException catch (e) {
      _message("Couldn't read the file: ${e.message ?? 'unknown error'}");
    }
  }

  Future<void> _importUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Import subscription URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://example.com/subscription'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Fetch')),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      _message('Enter a valid HTTP or HTTPS URL.');
      return;
    }
    try {
      _message('Downloading subscription…');
      final response = await http.get(uri).timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _message('Subscription request failed: HTTP ${response.statusCode}');
        return;
      }
      _importText(response.body);
    } catch (e) {
      _message('Could not download subscription: $e');
    }
  }

  Future<void> _scanQr() async {
    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _V2rayQrScannerPage()),
    );
    if (text != null) _importText(text);
  }

  Future<void> _showAddMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Symbols.edit_note_rounded), title: const Text('Add manually'), onTap: () => Navigator.pop(context, 'manual')),
            ListTile(leading: const Icon(Symbols.content_paste_rounded), title: const Text('Import from clipboard'), onTap: () => Navigator.pop(context, 'clipboard')),
            ListTile(leading: const Icon(Symbols.folder_open_rounded), title: const Text('Import file'), onTap: () => Navigator.pop(context, 'file')),
            ListTile(leading: const Icon(Symbols.qr_code_scanner_rounded), title: const Text('Scan QR code'), onTap: () => Navigator.pop(context, 'qr')),
            ListTile(leading: const Icon(Symbols.link_rounded), title: const Text('Import subscription URL'), onTap: () => Navigator.pop(context, 'url')),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'manual': await _manualImport();
      case 'clipboard': await _importClipboard();
      case 'file': await _importFile();
      case 'qr': await _scanQr();
      case 'url': await _importUrl();
      default: return;
    }
  }

  Future<void> _edit(ChainProxy config) async {
    final name = TextEditingController(text: config.name);
    final link = TextEditingController(text: config.link);
    final category = TextEditingController(text: config.category ?? '');
    final result = await showDialog<({String name, String link, String category})>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit configuration'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            TextField(controller: link, minLines: 2, maxLines: 5, decoration: const InputDecoration(labelText: 'Share link / config')),
            const SizedBox(height: 12),
            TextField(controller: category, decoration: const InputDecoration(labelText: 'Category')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, (name: name.text.trim(), link: link.text.trim(), category: category.text.trim())), child: const Text('Save')),
        ],
      ),
    );
    name.dispose(); link.dispose(); category.dispose();
    if (result == null) return;
    if (result.name.isEmpty) { _message('Name cannot be empty.'); return; }
    try {
      final parsed = parseChainProxies(result.link);
      if (parsed.length != 1) throw const FormatException('Enter exactly one configuration link.');
      final duplicate = AppScope.read(context).profile.chains.any((c) => c.id != config.id && c.link == parsed.single.link);
      if (duplicate) throw const FormatException('This configuration link is already saved.');
      AppScope.read(context).updateChain(config.copyWith(
        name: result.name,
        link: parsed.single.link,
        category: result.category.isEmpty ? null : result.category,
        clearCategory: result.category.isEmpty,
      ));
      _message('Configuration updated.');
    } on FormatException catch (e) { _message(e.message); }
  }

  Future<void> _delete(ChainProxy config) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete configuration?'),
        content: Text('Remove “${config.name}” from this device?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true && mounted) AppScope.read(context).deleteChain(config);
  }

  Future<void> _export(List<ChainProxy> configs, {required bool asFile}) async {
    if (configs.isEmpty) { _message('Select at least one configuration.'); return; }
    final text = configs.map((c) => c.link).join('\n');
    if (asFile) {
      try {
        await VpnChannel.saveFile(name: 'voidcore-configs.txt', content: text);
        _message('Export file prepared.');
      } on PlatformException catch (e) { _message('Export failed: ${e.message}'); }
    } else {
      await Clipboard.setData(ClipboardData(text: text));
      _message('Copied ${configs.length} configuration(s).');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final all = state.profile.chains;
    final categories = {'All', 'Favorites', ...all.map((c) => c.category).whereType<String>()};
    final query = _search.text.trim().toLowerCase();
    final configs = all.where((c) {
      final matchesCategory = _category == 'All' || (_category == 'Favorites' ? c.favorite : c.category == _category);
      final info = ChainInfo.of(c.link);
      final matchesSearch = query.isEmpty || c.name.toLowerCase().contains(query) || c.link.toLowerCase().contains(query) || (info?.protocol.toLowerCase().contains(query) ?? false);
      return matchesCategory && matchesSearch;
    }).toList();

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddMenu,
        icon: const Icon(Symbols.add_rounded),
        label: const Text('Add config'),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Configuration manager', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Import and organize supported share links. Configurations can be used as chain proxies in VOIDCORE.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                Row(children: [
                  FilledButton.icon(
                    onPressed: state.smartConnecting || state.isBusy || all.isEmpty
                        ? null
                        : () async {
                            final selected = await state.smartConnectV2ray();
                            if (!mounted) return;
                            _message(selected == null
                                ? (state.smartConnectionStatus ?? 'No suitable V2Ray server found.')
                                : 'Connected to ${selected.name}.');
                          },
                    icon: state.smartConnecting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Symbols.bolt_rounded),
                    label: const Text('Smart Connect'),
                  ),
                  const SizedBox(width: 10),
                  if (state.activeV2rayId != null)
                    Text(state.isConnected ? 'V2Ray connected' : 'V2Ray connecting…',
                        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
                ]),
                if (state.smartConnectionStatus != null) ...[
                  const SizedBox(height: 6),
                  Text(state.smartConnectionStatus!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
                const SizedBox(height: 14),
                SearchBar(
                  controller: _search,
                  hintText: 'Search configs…',
                  leading: const Icon(Symbols.search_rounded),
                  trailing: [IconButton(icon: const Icon(Symbols.close_rounded), onPressed: () { _search.clear(); setState(() {}); })],
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: Text('${configs.length} configuration(s)', style: theme.textTheme.labelLarge)),
                  TextButton.icon(
                    onPressed: () => setState(() { _selecting = !_selecting; _selected.clear(); }),
                    icon: Icon(_selecting ? Symbols.close_rounded : Symbols.checklist_rounded),
                    label: Text(_selecting ? 'Done' : 'Select'),
                  ),
                  if (_selecting)
                    TextButton(
                      onPressed: () => setState(() {
                        if (_selected.length == configs.length) {
                          _selected.clear();
                        } else {
                          _selected
                            ..clear()
                            ..addAll(configs.map((c) => c.id));
                        }
                      }),
                      child: Text(_selected.length == configs.length ? 'Deselect all' : 'Select all'),
                    ),
                  PopupMenuButton<String>(
                    tooltip: 'Export',
                    icon: const Icon(Symbols.ios_share_rounded),
                    onSelected: (value) => _export(value.startsWith('all-') ? configs : configs.where((c) => _selected.contains(c.id)).toList(), asFile: value.endsWith('file')),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'selected-copy', child: Text('Copy selected')),
                      PopupMenuItem(value: 'selected-file', child: Text('Save selected as file')),
                      PopupMenuDivider(),
                      PopupMenuItem(value: 'all-copy', child: Text('Copy all shown')),
                      PopupMenuItem(value: 'all-file', child: Text('Save all shown as file')),
                    ],
                  ),
                ]),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final category in categories)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: ChoiceChip(
                          label: Text(category),
                          selected: _category == category,
                          onSelected: (_) => setState(() => _category = category),
                        ),
                      ),
                  ]),
                ),
              ]),
            ),
          ),
          if (configs.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Symbols.add_link_rounded, size: 48, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  Text(all.isEmpty ? 'No configurations yet' : 'No matching configurations', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text('Use Add config to import a link, file, QR code or subscription.', textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ]),
              )),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
              sliver: SliverList.builder(
                itemCount: configs.length,
                itemBuilder: (context, index) {
                  final config = configs[index];
                  final info = ChainInfo.of(config.link);
                  final selected = _selected.contains(config.id);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Card(
                      color: state.activeV2rayId == config.id && state.isConnected ? theme.colorScheme.primaryContainer : null,
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                        child: Row(children: [
                          if (_selecting)
                            Checkbox(value: selected, onChanged: (v) => setState(() { if (v == true) { _selected.add(config.id); } else { _selected.remove(config.id); } })),
                          Expanded(child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: _selecting ? () => setState(() { if (selected) { _selected.remove(config.id); } else { _selected.add(config.id); } }) : null,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(config.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                                const SizedBox(height: 3),
                                Text(info?.address ?? 'Unsupported configuration', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                                const SizedBox(height: 7),
                                Wrap(spacing: 5, runSpacing: 4, children: [
                                  for (final tag in info?.tags ?? const ['Invalid']) Chip(label: Text(tag), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                                  if (config.category != null) Chip(label: Text(config.category!), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                                ]),
                              ]),
                            ),
                          )),
                          if (!_selecting) ...[
                            IconButton(
                              tooltip: 'Test TCP latency',
                              onPressed: _probing.contains(config.id) ? null : () => _probe(config),
                              icon: _probing.contains(config.id)
                                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Symbols.speed_rounded),
                            ),
                            if (state.activeV2rayId == config.id && state.isConnected)
                              IconButton(
                                tooltip: 'Disconnect V2Ray',
                                onPressed: state.isBusy ? null : () => state.disconnect(),
                                icon: const Icon(Symbols.stop_circle_rounded),
                              )
                            else
                              IconButton(
                                tooltip: 'Connect with V2Ray',
                                onPressed: state.isBusy || state.smartConnecting
                                    ? null
                                    : () async {
                                        final connected = await state.connectV2ray(config);
                                        if (mounted) _message(connected ? 'Connected to ${config.name}.' : (state.error ?? 'Connection failed.'));
                                      },
                                icon: state.activeV2rayId == config.id && state.status == VpnStatus.connecting
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Symbols.play_circle_rounded),
                              ),
                            IconButton(tooltip: config.favorite ? 'Remove favorite' : 'Add favorite', onPressed: () => state.updateChain(config.copyWith(favorite: !config.favorite)), icon: Icon(config.favorite ? Symbols.star_rounded : Symbols.star_outline_rounded, color: config.favorite ? theme.colorScheme.primary : null)),
                            PopupMenuButton<String>(
                              onSelected: (value) {
                                switch (value) {
                                  case 'edit': _edit(config);
                                  case 'duplicate': state.duplicateChain(config); _message('Configuration duplicated.');
                                  case 'copy': Clipboard.setData(ClipboardData(text: config.link)); _message('Link copied.');
                                  case 'delete': _delete(config);
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'edit', child: Text('Edit')),
                                PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                                PopupMenuItem(value: 'copy', child: Text('Copy link')),
                                PopupMenuDivider(),
                                PopupMenuItem(value: 'delete', child: Text('Delete')),
                              ],
                            ),
                          ],
                        ]),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _V2rayQrScannerPage extends StatefulWidget {
  const _V2rayQrScannerPage();
  @override
  State<_V2rayQrScannerPage> createState() => _V2rayQrScannerPageState();
}

class _V2rayQrScannerPageState extends State<_V2rayQrScannerPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan configuration QR')),
    body: MobileScanner(
      controller: _controller,
      onDetect: (capture) {
        final value = capture.barcodes.map((b) => b.rawValue).nonNulls.firstOrNull;
        if (_done || value == null) return;
        _done = true;
        Navigator.of(context).pop(value);
      },
    ),
  );
}
