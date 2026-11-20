import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/app_state.dart';
import 'theme.dart';

class SmartConnectionCard extends StatelessWidget {
  const SmartConnectionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: scheme.surfaceContainer,
      elevation: 0,
      shape: roundedShape(kCardRadius, side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .7))),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Symbols.bolt_rounded, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text('Smart Connection', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
            if (state.smartConnecting) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 6),
          Text(
            'Check saved V2Ray server endpoints without starting VPN tunnels, then connect to the lowest-latency reachable profile.',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (state.smartConnectionStatus != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
              child: Text(state.smartConnectionStatus!, style: theme.textTheme.bodyMedium),
            ),
          ],
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: state.smartConnecting || state.isBusy || state.profile.chains.isEmpty ? null : state.smartConnectV2ray,
                icon: const Icon(Symbols.speed_rounded),
                label: const Text('Smart Connect'),
              ),
            ),
            if (state.smartConnecting) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: state.cancelSmartConnect,
                icon: const Icon(Symbols.close_rounded),
                label: const Text('Cancel'),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          Text(
            'TCP endpoints are measured directly without a VPN tunnel. UDP-only profiles are not assigned a fake ping. If the first real Xray connection fails, Smart Connect tries the next reachable profile.',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}
