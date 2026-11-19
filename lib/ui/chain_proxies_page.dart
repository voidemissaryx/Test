import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:http/http.dart' as http;

import '../models/settings.dart';
import '../services/chain_proxy.dart';
import '../services/vpn_channel.dart';
import '../state/app_state.dart';
import 'chip_menu.dart';
import 'prefs.dart';

/// Settings → Chain proxies: the saved configs a connection can exit through (picked per
/// connection type on the home page). Added from the clipboard, a QR code or a WireGuard file.
class ChainProxiesPage extends StatelessWidget {
  const ChainProxiesPage({super.key});

  /// Adds the chain proxies in [text], or says why there are none.
  static void _import(BuildContext context, String? text, {String? fileName}) {
    if (text == null || text.trim().isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final chains = parseChainProxies(text, fileName: fileName);
      final state = AppScope.read(context);
      final existing = state.profile.chains.map((c) => c.link).toSet();
      final fresh = chains.where((c) => !existing.contains(c.link)).toList();
      if (fresh.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('These configs are already imported.')));
        return;
      }
      state.addChains(fresh);
      messenger.showSnackBar(
        SnackBar(content: Text(fresh.length == 1 ? 'Added ${fresh.single.name}' : 'Added ${fresh.length} configs')),
      );
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _add(BuildContext context) async {
    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('Add manually'),
              subtitle: const Text('Paste one or more supported proxy links'),
              onTap: () => Navigator.of(context).pop('manual'),
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Import subscription URL'),
              subtitle: const Text('Download and validate a supported subscription'),
              onTap: () => Navigator.of(context).pop('url'),
            ),
            ListTile(
              leading: const Icon(Symbols.content_paste_rounded),
              title: const Text('Import from clipboard'),
              subtitle: const Text('v2ray links or WireGuard configs'),
              onTap: () => Navigator.of(context).pop('clipboard'),
            ),
            ListTile(
              leading: const Icon(Symbols.qr_code_rounded),
              title: const Text('Scan QR code'),
              onTap: () => Navigator.of(context).pop('qr'),
            ),
            ListTile(
              leading: const Icon(Symbols.folder_rounded),
              title: const Text('Import config file'),
              onTap: () => Navigator.of(context).pop('file'),
            ),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    String? text;
    String? fileName;
    try {
      switch (source) {
        case 'manual':
          text = await _manualInput(context);
        case 'url':
          final url = await _urlInput(context);
          if (url == null || url.trim().isEmpty) return;
          final uri = Uri.tryParse(url.trim());
          if (uri == null || !{'http', 'https'}.contains(uri.scheme)) {
            throw const FormatException('Enter a valid HTTP or HTTPS subscription URL.');
          }
          final response = await http.get(uri).timeout(const Duration(seconds: 20));
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw FormatException('Subscription request failed (HTTP ${response.statusCode}).');
          }
          text = response.body;
          try {
            final decoded = utf8.decode(base64.decode(base64.normalize(text!.trim().replaceAll(RegExp(r'\s+'), ''))));
            if (decoded.contains('://')) text = decoded;
          } catch (_) {}
        case 'clipboard':
          text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        case 'qr':
          text = await navigator.push<String>(MaterialPageRoute(builder: (_) => const _QrScanPage()));
        default:
          final file = await VpnChannel.pickFile();
          text = file?.content;
          fileName = file?.name;
      }
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't read the file: ${e.message}")));
      return;
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
      return;
    }
    if (source == 'clipboard' && (text == null || text.trim().isEmpty)) {
      messenger.showSnackBar(const SnackBar(content: Text('The clipboard is empty')));
      return;
    }
    if (context.mounted) _import(context, text, fileName: fileName);
  }

  Future<String?> _manualInput(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add config manually'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            minLines: 4,
            maxLines: 9,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'vless://…\nvmess://…\ntrojan://…',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Validate & add')),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<String?> _urlInput(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import subscription URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://example.com/subscription'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Import')),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final chains = [...state.profile.chains]..sort((a, b) => (b.favorite ? 1 : 0).compareTo(a.favorite ? 1 : 0));
    return Scaffold(
      appBar: AppBar(title: const Text('Chain proxies')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context),
        icon: const Icon(Symbols.add_rounded),
        label: const Text('Add config'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Text(
              'Traffic exits through the chain proxy when Chain proxy is selected as the exit node.\n'
              'WireGuard and Hysteria protocols work over WARP and MASQUE only.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          // A card per config.
          for (final c in chains)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SettingsCard(children: [_ChainTile(chain: c)]),
            ),
        ],
      ),
    );
  }
}

/// A chain proxy: its name, address and tags, and copy / QR / delete.
class _ChainTile extends StatelessWidget {
  final ChainProxy chain;
  const _ChainTile({required this.chain});

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: chain.link));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  Future<void> _export(BuildContext context) async {
    try {
      await VpnChannel.shareFile(
        name: '${chain.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.txt',
        content: chain.link,
        title: 'Export ${chain.name}',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  void _showQr(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(chain.name),
      content: SizedBox(
        width: 260,
        height: 260,
        // Dark modules on white whatever the theme, so every scanner reads it.
        child: QrImageView(data: chain.link, backgroundColor: Colors.white, padding: const EdgeInsets.all(12)),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    ),
  );

  Future<void> _edit(BuildContext context) async {
    final name = TextEditingController(text: chain.name);
    final link = TextEditingController(text: chain.link);
    final category = TextEditingController(text: chain.category);
    final result = await showDialog<({String name, String link, String category})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit config'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: link, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Share link')),
            TextField(controller: category, decoration: const InputDecoration(labelText: 'Category (optional)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, (name: name.text.trim(), link: link.text.trim(), category: category.text.trim())), child: const Text('Save')),
        ],
      ),
    );
    name.dispose();
    link.dispose();
    category.dispose();
    if (result == null || !context.mounted) return;
    try {
      final parsed = ChainInfo.of(result.link);
      if (parsed == null || result.name.isEmpty) throw const FormatException('Name or supported link is invalid.');
      final state = AppScope.read(context);
      state.deleteChain(chain);
      state.addChains([ChainProxy(
        id: chain.id,
        name: result.name,
        link: result.link,
        favorite: chain.favorite,
        category: result.category,
      )]);
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _duplicate(BuildContext context) {
    AppScope.read(context).addChains([
      ChainProxy(id: newChainId(), name: '${chain.name} copy', link: chain.link, category: chain.category),
    ]);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Config duplicated')));
  }

  void _toggleFavorite(BuildContext context) {
    AppScope.read(context).updateChain(ChainProxy(
      id: chain.id,
      name: chain.name,
      link: chain.link,
      favorite: !chain.favorite,
      category: chain.category,
    ));
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete config?'),
        content: Text('${chain.name} will be removed from the chain proxies.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && context.mounted) AppScope.read(context).deleteChain(chain);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = ChainInfo.of(chain.link);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(chain.name, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  info?.address ?? 'Invalid link',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: info == null ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (chain.category.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(chain.category, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
                ],
                if (info != null) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [for (final tag in info.tags) ChipMenu.badge(context, tag)],
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: chain.favorite ? 'Remove favorite' : 'Add favorite',
            icon: Icon(chain.favorite ? Icons.star : Icons.star_border),
            onPressed: () => _toggleFavorite(context),
          ),
          IconButton(
            tooltip: 'Copy link',
            icon: const Icon(Symbols.content_copy_rounded),
            onPressed: () => _copy(context),
          ),
          IconButton(
            tooltip: 'Export config',
            icon: const Icon(Icons.ios_share),
            onPressed: () => _export(context),
          ),
          IconButton(
            tooltip: 'QR code',
            icon: const Icon(Symbols.qr_code_rounded),
            onPressed: () => _showQr(context),
          ),
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit),
            onPressed: () => _edit(context),
          ),
          IconButton(
            tooltip: 'Duplicate',
            icon: const Icon(Icons.copy_all),
            onPressed: () => _duplicate(context),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Symbols.delete_rounded),
            onPressed: () => _delete(context),
          ),
        ],
      ),
    );
  }
}

/// The camera, until it sees a QR code; pops with its text.
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan QR code')),
    body: MobileScanner(
      controller: _controller,
      onDetect: (capture) {
        final text = capture.barcodes.map((b) => b.rawValue).nonNulls.firstOrNull;
        if (_done || text == null) return;
        _done = true;
        Navigator.of(context).pop(text);
      },
    ),
  );
}
