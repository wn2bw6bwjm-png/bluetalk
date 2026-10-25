import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_core/mesh_core.dart' show TransportKind;
import 'package:mesh_engine/mesh_engine.dart';

import '../application/app_controller.dart';
import 'chat_page.dart';
import 'widgets/common.dart';
import 'widgets/engine_access.dart';

/// Devices around you: connection state, names, transport, public rooms,
/// and adding contacts by QR / pasted text. Everything is local.
class NearbyTab extends ConsumerWidget {
  const NearbyTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = engineOf(ref);
    final app = ref.watch(appControllerProvider);
    if (engine == null) return const Center(child: CircularProgressIndicator());

    final peers = engine.peers.all().where((p) => !p.blocked).toList()
      ..sort((a, b) {
        final ca = engine.isConnected(a.identity.peerId) ? 0 : engine.isReachable(a.identity.peerId) ? 1 : 2;
        final cb = engine.isConnected(b.identity.peerId) ? 0 : engine.isReachable(b.identity.peerId) ? 1 : 2;
        return ca != cb ? ca.compareTo(cb) : b.lastSeen.compareTo(a.lastSeen);
      });
    final transport = app.networkRunning
        ? (Theme.of(context).platform == TargetPlatform.iOS ? 'Multipeer' : 'Bluetooth LE')
        : '—';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby'),
        actions: [
          IconButton(
            tooltip: 'My contact card',
            icon: const Icon(Icons.qr_code),
            onPressed: () async {
              final card = await guarded(context, engine.createContactInvite);
              if (card != null && context.mounted) {
                await showQrDialog(context, 'My contact card', card.toText());
              }
            },
          ),
          IconButton(
            tooltip: 'Add contact',
            icon: const Icon(Icons.person_add_alt),
            onPressed: () async {
              final text = await askForInvite(context);
              if (text == null || text.isEmpty || !context.mounted) return;
              final who = await guarded(context, () => engine.redeemInvite(text));
              if (who != null && context.mounted) toast(context, 'Added ${engine.peers.get(who.peerId)?.title}');
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          if (app.networkError != null)
            MaterialBanner(
              content: Text(app.networkError!),
              actions: [
                TextButton(
                  onPressed: () => ref.read(appControllerProvider.notifier).startNetwork(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ListTile(
            leading: Icon(app.networkRunning ? Icons.radar : Icons.portable_wifi_off),
            title: Text(app.networkRunning ? 'Scanning · $transport' : 'Radio is off'),
            subtitle: Text('${engine.linkCount} direct link(s)'),
          ),
          if (engine.nearbyDevices.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Devices found (connecting…)'),
            ),
            for (final d in engine.nearbyDevices)
              ListTile(
                leading: const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: const Text('BlueTalk device'),
                subtitle: Text(
                  '${_signal(d.rssi)} · the name appears once it is connected',
                ),
              ),
            const Divider(),
          ],
          if (engine.nearbyRooms.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Public rooms nearby'),
            ),
            for (final r in engine.nearbyRooms)
              ListTile(
                leading: const Icon(Icons.groups),
                title: Text(r.name),
                subtitle: Text('via ${engine.peers.get(r.via.peerId)?.title ?? r.via.shortId}'),
                trailing: FilledButton(
                  onPressed: () async {
                    await guarded(context, () => engine.joinPublicRoom(r));
                    if (context.mounted) toast(context, 'Join requested');
                  },
                  child: const Text('Join'),
                ),
              ),
            const Divider(),
          ],
          if (peers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No devices seen yet.\nOpen the app on another nearby phone, '
                'or add a contact with their QR code.',
                textAlign: TextAlign.center,
              ),
            ),
          for (final p in peers) _PeerTile(engine, p),
        ],
      ),
    );
  }
}

String _signal(int? rssi) {
  if (rssi == null) return 'signal unknown';
  final label = rssi >= -60 ? 'strong' : rssi >= -80 ? 'medium' : 'weak';
  return '$label signal ($rssi dBm)';
}

class _PeerTile extends StatelessWidget {
  const _PeerTile(this.engine, this.p);
  final MeshEngine engine;
  final StoredPeer p;

  @override
  Widget build(BuildContext context) {
    final direct = engine.isConnected(p.identity.peerId);
    final reach = engine.isReachable(p.identity.peerId);
    final transport = engine.transportOf(p.identity.peerId);
    final via = transport == null
        ? ''
        : ' · ${transport == TransportKind.multipeer ? 'Multipeer' : 'Bluetooth LE'}';
    final state = direct ? 'Connected$via' : reach ? 'Reachable via relay' : 'Offline';
    final color = direct ? Colors.green : reach ? Colors.orange : Colors.grey;
    return ListTile(
      leading: Stack(children: [
        PeerAvatar(p.title),
        Positioned(
          right: 0,
          bottom: 0,
          child: CircleAvatar(radius: 5, backgroundColor: color),
        ),
      ]),
      title: Row(children: [
        Flexible(child: Text(p.title, overflow: TextOverflow.ellipsis)),
        if (p.verified) const Padding(
          padding: EdgeInsets.only(left: 4),
          child: Icon(Icons.verified_user, size: 14),
        ),
      ]),
      subtitle: Text([
        if (p.status != null) p.status!,
        '$state · ${p.identity.shortId}',
      ].join('\n')),
      isThreeLine: p.status != null,
      trailing: p.muted ? const Icon(Icons.notifications_off, size: 16) : null,
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChatPage(kind: ConvKind.direct, convId: p.identity.peerId),
      )),
    );
  }
}
