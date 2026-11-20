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
  bool _pingAllRunning = false;
  bool _cancelPingAll = false;
  int _pingAllProgress = 0;
  String _sortMode = 'default';

  Future<int?> _measureTcpLatency(ChainProxy config) async {
    final info = ChainInfo.of(config.link);
    if (info == null || info.isUdp) return null;
    Socket? socket;
    try {
      final watch = Stopwatch()..start();
      socket = await Socket.connect(
        info.uri.server,
        info.uri.port,
        timeout: const Duration(seconds: 4),
      );
      watch.stop();
      return watch.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _probe(ChainProxy config) async {
    final info = ChainInfo.of(config.link);
    if (info == null) {
      _message('This configuration is invalid.');
      return;
    }
    if (info.isUdp) {
      _message('This is a UDP-only profile; a direct TCP ping is unavailable.');
      return;
    }
    if (AppScope.read(context).status != VpnStatus.disconnected) {
      _message('Disconnect the active connection before testing direct server latency.');
      return;
    }
    if (_pingAllRunning || _probing.contains(config.id)) return;
    setState(() => _probing.add(config.id));
    try {
      final latency = await _measureTcpLatency(config);
      if (!mounted) return;
      setState(() => _latencies[config.id] = latency ?? -1);
      _message(latency == null || latency < 0
          ? '${config.name}: server is not reachable over TCP.'
          : '${config.name}: ${latency} ms TCP latency');
    } finally {
      if (mounted) setState(() => _probing.remove(config.id));
    }
  }

  Future<void> _pingAll(List<ChainProxy> configs) async {
    if (_pingAllRunning || configs.isEmpty) return;
    final state = AppScope.read(context);
    if (state.status != VpnStatus.disconnected || state.smartConnecting || state.v2raySmartConnecting) {
      _message('Disconnect the active connection before running Ping All.');
      return;
    }
    setState(() {
      _pingAllRunning = true;
      _cancelPingAll = false;
      _pingAllProgress = 0;
      _probing.clear();
    });
    var reachable = 0;
    var unreachable = 0;
    var udpSkipped = 0;
    var invalid = 0;
    try {
      // Small batches avoid opening too many sockets on mobile devices at once.
      for (var offset = 0; offset < configs.length; offset += 8) {
        if (_cancelPingAll) break;
        final batch = configs.skip(offset).take(8).toList();
        if (mounted) setState(() => _probing.addAll(batch.map((c) => c.id)));
        final results = await Future.wait(batch.map((config) async {
          final info = ChainInfo.of(config.link);
          if (info == null) {
            return (id: config.id, latency: -1, udp: false, invalid: true);
          }
          if (info.isUdp) {
            return (id: config.id, latency: -1, udp: true, invalid: false);
          }
          final latency = await _measureTcpLatency(config);
          return (id: config.id, latency: latency ?? -1, udp: false, invalid: false);
        }));
        if (!mounted) return;
        setState(() {
          for (final result in results) {
            _probing.remove(result.id);
            if (result.udp) {
              udpSkipped++;
            } else if (result.invalid) {
              invalid++;
              _latencies[result.id] = -1;
            } else if (result.latency < 0) {
              unreachable++;
              _latencies[result.id] = -1;
            } else {
              reachable++;
              _latencies[result.id] = result.latency;
            }
          }
          _pingAllProgress += batch.length;
        });
      }
      if (!mounted) return;
      _message(_cancelPingAll
          ? 'Ping All cancelled · $reachable reachable, $unreachable unreachable.'
          : 'Ping All complete · $reachable reachable, $unreachable unreachable, $udpSkipped UDP-only skipped, $invalid invalid.');
    } finally {
      if (mounted) {
        setState(() {
          _pingAllRunning = false;
          _probing.clear();
        });
      }
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

  Future<List<String>?> _chooseV2rayApps({required List<String> initial}) async {
    try {
      final apps = await VpnChannel.installedApps();
      if (!mounted) return null;
      final selected = Set<String>.from(initial);
      final result = await showDialog<List<String>>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('V2Ray app selection'),
            content: SizedBox(
              width: 460,
              height: 420,
              child: apps.isEmpty
                  ? const Center(child: Text('No installed apps were found.'))
                  : ListView.builder(
                      itemCount: apps.length,
                      itemBuilder: (context, index) {
                        final app = apps[index];
                        return CheckboxListTile(
                          value: selected.contains(app.packageName),
                          title: Text(app.label),
                          subtitle: Text(app.packageName),
                          onChanged: (checked) => setDialogState(() {
                            if (checked == true) { selected.add(app.packageName); }
                            else { selected.remove(app.packageName); }
                          }),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, selected.toList()), child: const Text('Save selection')),
            ],
          ),
        ),
      );
      return result;
    } catch (e) {
      _message('Could not load installed apps: $e');
      return null;
    }
  }

  Future<void> _workspaceSettings() async {
    final state = AppScope.read(context);
    var appMode = state.v2rayAppMode;
    var perAppMode = state.v2rayPerAppMode;
    var apps = List<String>.of(state.v2rayPerAppApps);
    var mtu = state.v2rayMtu;
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('V2Ray workspace settings'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<AppMode>(
                value: appMode,
                decoration: const InputDecoration(labelText: 'Connection mode'),
                items: const [
                  DropdownMenuItem(value: AppMode.vpn, child: Text('VPN (all device traffic)')),
                  DropdownMenuItem(value: AppMode.proxy, child: Text('Local proxy only')),
                ],
                onChanged: (value) { if (value != null) setDialogState(() => appMode = value); },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<PerAppMode>(
                value: perAppMode,
                decoration: const InputDecoration(labelText: 'Per-app mode'),
                items: const [
                  DropdownMenuItem(value: PerAppMode.off, child: Text('Off')),
                  DropdownMenuItem(value: PerAppMode.include, child: Text('Include selected apps')),
                  DropdownMenuItem(value: PerAppMode.exclude, child: Text('Exclude selected apps')),
                ],
                onChanged: (value) { if (value != null) setDialogState(() => perAppMode = value); },
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final chosen = await _chooseV2rayApps(initial: apps);
                    if (chosen != null) setDialogState(() => apps = chosen);
                  },
                  icon: const Icon(Symbols.apps_rounded),
                  label: Text('Choose apps (${apps.length})'),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: '$mtu',
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'MTU', helperText: 'Allowed range: 576–9000'),
                onChanged: (value) { final parsed = int.tryParse(value); if (parsed != null) mtu = parsed.clamp(576, 9000).toInt(); },
              ),
              const SizedBox(height: 8),
              Text('These settings are saved separately and do not change the main VPN modes.', style: Theme.of(dialogContext).textTheme.bodySmall),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (save == true && mounted) {
      state.updateV2raySettings(appMode: appMode, perAppMode: perAppMode, apps: apps, mtu: mtu);
      _message('V2Ray workspace settings saved.');
    }
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
      final before = state.v2rayConfigs.length;
      state.addV2rayConfigs(configs);
      final added = state.v2rayConfigs.length - before;
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
      final duplicate = AppScope.read(context).v2rayConfigs.any((c) => c.id != config.id && c.link == parsed.single.link);
      if (duplicate) throw const FormatException('This configuration link is already saved.');
      AppScope.read(context).updateV2rayConfig(config.copyWith(
        name: result.name,
        link: parsed.single.link,
        category: result.category.isEmpty ? null : result.category,
        clearCategory: result.category.isEmpty,
      ));
      _message('Configuration updated.');
    } on FormatException catch (e) { _message(e.message); }
  }

  Future<void> _deleteSelected(List<ChainProxy> configs) async {
    final targets = configs.where((c) => _selected.contains(c.id)).toList();
    if (targets.isEmpty) { _message('Select at least one configuration.'); return; }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete selected configurations?'),
        content: Text('Permanently remove ${targets.length} selected configuration(s) from this device?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete all')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final state = AppScope.read(context);
    for (final config in targets) { state.deleteV2rayConfig(config); }
    setState(() { _selected.clear(); _selecting = false; });
    _message('${targets.length} configuration(s) deleted.');
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
    if (confirmed == true && mounted) AppScope.read(context).deleteV2rayConfig(config);
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
    final all = state.v2rayConfigs;
    final categories = {'All', 'Favorites', ...all.map((c) => c.category).whereType<String>()};
    final query = _search.text.trim().toLowerCase();
    final configs = all.where((c) {
      final matchesCategory = _category == 'All' || (_category == 'Favorites' ? c.favorite : c.category == _category);
      final info = ChainInfo.of(c.link);
      final matchesSearch = query.isEmpty || c.name.toLowerCase().contains(query) || c.link.toLowerCase().contains(query) || (info?.protocol.toLowerCase().contains(query) ?? false);
      return matchesCategory && matchesSearch;
    }).toList();
    if (_sortMode == 'name') {
      configs.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } else if (_sortMode == 'ping') {
      int rank(ChainProxy config) {
        final value = _latencies[config.id];
        return value == null || value < 0 ? 1 << 30 : value;
      }
      configs.sort((a, b) {
        final byLatency = rank(a).compareTo(rank(b));
        return byLatency != 0 ? byLatency : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    }

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
                _V2rayPowerCard(onMessage: _message),
                const SizedBox(height: 14),
                Text('V2Ray workspace', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Manage profiles, test server latency, and connect through the shared Xray engine.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                  FilledButton.icon(
                    onPressed: _pingAllRunning || state.v2raySmartConnecting || state.smartConnecting || state.isBusy || all.isEmpty
                        ? null
                        : () async {
                            final selected = await state.smartConnectV2ray();
                            if (!mounted) return;
                            _message(selected == null
                                ? (state.v2raySmartConnectionStatus ?? 'No suitable V2Ray server found.')
                                : 'Connected to ${selected.name}.');
                          },
                    icon: state.v2raySmartConnecting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Symbols.bolt_rounded),
                    label: const Text('V2Ray Smart Connect'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _pingAllRunning
                        ? () => setState(() => _cancelPingAll = true)
                        : (all.isEmpty || state.status != VpnStatus.disconnected || state.smartConnecting || state.v2raySmartConnecting)
                            ? null
                            : () => _pingAll(all),
                    icon: _pingAllRunning
                        ? const Icon(Symbols.close_rounded)
                        : const Icon(Symbols.speed_rounded),
                    label: Text(_pingAllRunning ? 'Cancel ping' : 'Ping all'),
                  ),
                  if (state.v2raySmartConnecting) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: state.cancelV2raySmartConnect,
                      icon: const Icon(Symbols.close_rounded),
                      label: const Text('Cancel'),
                    ),
                  ],
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: state.isBusy || state.smartConnecting || state.v2raySmartConnecting ? null : _workspaceSettings,
                    icon: const Icon(Symbols.settings_rounded),
                    label: const Text('Settings'),
                  ),
                  if (state.v2rayNeedsReconnect && state.activeV2rayId != null)
                    TextButton.icon(
                      onPressed: state.isBusy ? null : state.reconnect,
                      icon: const Icon(Symbols.refresh_rounded),
                      label: const Text('Apply settings'),
                    ),
                ]),
                if (_pingAllRunning) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: all.isEmpty ? null : _pingAllProgress / all.length,
                    minHeight: 4,
                  ),
                  const SizedBox(height: 4),
                  Text('Testing servers · $_pingAllProgress / ${all.length}', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
                if (state.v2rayNeedsReconnect && state.activeV2rayId != null) ...[
                  const SizedBox(height: 6),
                  Text('V2Ray settings changed · reconnect to apply', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.tertiary)),
                ],
                if (state.v2raySmartConnectionStatus != null) ...[
                  const SizedBox(height: 6),
                  Text(state.v2raySmartConnectionStatus!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
                  PopupMenuButton<String>(
                    tooltip: 'Sort configurations',
                    initialValue: _sortMode,
                    onSelected: (value) => setState(() => _sortMode = value),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'default', child: Text('Default order')),
                      PopupMenuItem(value: 'ping', child: Text('Lowest ping first')),
                      PopupMenuItem(value: 'name', child: Text('Name A–Z')),
                    ],
                    icon: const Icon(Symbols.sort_rounded),
                  ),
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
                  if (_selecting)
                    TextButton.icon(
                      onPressed: _selected.isEmpty ? null : () => _deleteSelected(configs),
                      icon: const Icon(Symbols.delete_outline_rounded),
                      label: Text('Delete${_selected.isEmpty ? '' : ' (${_selected.length})'}'),
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
                      color: state.activeV2rayId == config.id && state.isConnected
                          ? theme.colorScheme.primaryContainer
                          : state.selectedV2rayId == config.id
                              ? theme.colorScheme.secondaryContainer
                              : null,
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                        child: Row(children: [
                          if (_selecting)
                            Checkbox(value: selected, onChanged: (v) => setState(() { if (v == true) { _selected.add(config.id); } else { _selected.remove(config.id); } })),
                          Expanded(child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: _selecting
                                ? () => setState(() { if (selected) { _selected.remove(config.id); } else { _selected.add(config.id); } })
                                : () => state.selectV2ray(config),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(config.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                                const SizedBox(height: 3),
                                Text(
                                  info == null
                                      ? 'Unsupported configuration'
                                      : info.isUdp
                                          ? '${info.address} · UDP · TCP ping unavailable'
                                          : '${info.address}${_latencies.containsKey(config.id) ? ' · ${_latencies[config.id]! < 0 ? 'Timeout' : '${_latencies[config.id]} ms'}' : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                ),
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
                              onPressed: _pingAllRunning || _probing.contains(config.id) ? null : () => _probe(config),
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
                                onPressed: _pingAllRunning || state.isBusy || state.smartConnecting || state.v2raySmartConnecting
                                    ? null
                                    : () async {
                                        final connected = await state.connectV2ray(config);
                                        if (mounted) _message(connected ? 'Connected to ${config.name}.' : (state.error ?? 'Connection failed.'));
                                      },
                                icon: state.activeV2rayId == config.id && state.status == VpnStatus.connecting
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Symbols.play_circle_rounded),
                              ),
                            IconButton(tooltip: config.favorite ? 'Remove favorite' : 'Add favorite', onPressed: () => state.updateV2rayConfig(config.copyWith(favorite: !config.favorite)), icon: Icon(config.favorite ? Symbols.star_rounded : Symbols.star_outline_rounded, color: config.favorite ? theme.colorScheme.primary : null)),
                            PopupMenuButton<String>(
                              onSelected: (value) {
                                switch (value) {
                                  case 'edit': _edit(config);
                                  case 'duplicate': state.duplicateV2rayConfig(config); _message('Configuration duplicated.');
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

class _V2rayPowerCard extends StatelessWidget {
  final ValueChanged<String> onMessage;
  const _V2rayPowerCard({required this.onMessage});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final activeId = state.activeV2rayId;
    final activeConfig = activeId == null
        ? null
        : state.v2rayConfigs.where((c) => c.id == activeId).firstOrNull;
    final selectedConfig = state.v2rayConfigs
        .where((c) => c.id == state.selectedV2rayId)
        .firstOrNull;
    final connected = activeId != null && state.isConnected;
    final connecting = activeId != null && state.status == VpnStatus.connecting;
    final busy = state.isBusy;
    final blockedByVoidCore = activeId == null && state.status != VpnStatus.disconnected;
    final canTap = state.v2raySmartConnecting
        ? false
        : activeId != null
            ? true
            : !busy && !blockedByVoidCore && selectedConfig != null;
    final Color fill = connected
        ? const Color(0xFF1FA463)
        : (connecting || busy ? scheme.primary : scheme.primaryContainer);
    final Color iconColor = connected
        ? Colors.white
        : (connecting || busy ? scheme.onPrimary : scheme.onPrimaryContainer);
    final statusText = connected
        ? 'V2Ray connected'
        : connecting
            ? 'Connecting to V2Ray…'
            : state.status == VpnStatus.disconnecting && activeId != null
                ? 'Disconnecting…'
                : blockedByVoidCore
                    ? 'Disconnect VOIDCORE before using V2Ray'
                    : selectedConfig == null
                        ? 'Select or import a V2Ray profile'
                        : 'Ready to connect';
    final profileText = activeConfig?.name ?? selectedConfig?.name ?? 'No profile selected';

    Future<void> toggle() async {
      if (activeId != null) {
        await state.disconnect();
        onMessage('V2Ray disconnected.');
        return;
      }
      if (blockedByVoidCore) {
        onMessage('Disconnect the active VOIDCORE connection first.');
        return;
      }
      final config = selectedConfig;
      if (config == null) {
        onMessage('Select a V2Ray profile first.');
        return;
      }
      final ok = await state.connectV2ray(config);
      onMessage(ok ? 'Connected to ${config.name}.' : (state.error ?? 'V2Ray connection failed.'));
    }

    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainer,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .75)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
        child: Column(
          children: [
            Text('V2Ray Connection', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            Semantics(
              button: true,
              label: connected ? 'Disconnect V2Ray' : 'Connect selected V2Ray profile',
              child: InkWell(
                onTap: canTap ? toggle : null,
                customBorder: const CircleBorder(),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color.lerp(fill, Colors.white, .18)!, fill],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: fill.withValues(alpha: connected ? .45 : .25),
                        blurRadius: connected ? 26 : 18,
                        offset: const Offset(0, 7),
                      ),
                    ],
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (busy)
                        const SizedBox(
                          width: 78,
                          height: 78,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            strokeCap: StrokeCap.round,
                            color: Colors.white,
                          ),
                        ),
                      Icon(Symbols.power_settings_new_rounded, size: 42, color: iconColor),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(statusText, style: theme.textTheme.titleSmall?.copyWith(
              color: connected ? const Color(0xFF1FA463) : scheme.onSurface,
              fontWeight: FontWeight.w700,
            ), textAlign: TextAlign.center),
            const SizedBox(height: 3),
            Text(profileText, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
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
