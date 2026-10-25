import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_engine/mesh_engine.dart';

import '../application/app_controller.dart';
import 'room_page.dart';
import 'theme_builder.dart';
import 'widgets/common.dart';
import 'widgets/engine_access.dart';

class RoomsTab extends ConsumerWidget {
  const RoomsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = engineOf(ref);
    if (engine == null) return const Center(child: CircularProgressIndicator());
    final theme = ref.watch(appControllerProvider.select((s) => s.theme));
    final rooms = engine.roomStore.rooms();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rooms'),
        actions: [
          IconButton(
            tooltip: 'Join with invite',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => _redeem(context, engine),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New room',
        onPressed: () => _create(context, engine),
        child: const Icon(Icons.add),
      ),
      body: rooms.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No rooms yet.\nCreate one, scan an invite, or join a '
                  'public room from Nearby.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              itemCount: rooms.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final r = rooms[i];
                final color = roomColor(context, theme, r.idHex, r.color);
                final members = engine.roomStore.members(r.roomId);
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: color,
                    child: Text(r.icon.isEmpty ? r.name.characters.first.toUpperCase() : r.icon,
                        style: const TextStyle(color: Colors.white)),
                  ),
                  title: Text(r.name),
                  subtitle: Text(
                    '${r.isPublic ? 'Public' : 'Private'} · ${members.length} members'
                    '${r.active ? '' : ' · you are not a member'}'
                    '${r.deleted ? ' · deleted' : ''}',
                  ),
                  trailing: r.muted ? const Icon(Icons.notifications_off, size: 18) : null,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => RoomPage(roomId: r.roomId))),
                );
              },
            ),
    );
  }

  Future<void> _redeem(BuildContext context, MeshEngine engine) async {
    final text = await askForInvite(context);
    if (text == null || text.isEmpty || !context.mounted) return;
    final who = await guarded(context, () => engine.redeemInvite(text));
    if (who != null && context.mounted) {
      toast(context,
          'Invite accepted. You will be added when ${engine.peers.get(who.peerId)?.title ?? 'the inviter'} is reachable.');
    }
  }

  Future<void> _create(BuildContext context, MeshEngine engine) async {
    final name = TextEditingController();
    final desc = TextEditingController();
    var isPublic = false;
    int? color;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => AlertDialog(
          title: const Text('New room'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: name,
                autofocus: true,
                maxLength: 64,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: desc,
                maxLength: 256,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Public'),
                subtitle: const Text(
                    'Nearby people can see it and join without an invite. '
                    'Private rooms need an invite.'),
                value: isPublic,
                onChanged: (v) => setS(() => isPublic = v),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Colour'),
                trailing: CircleAvatar(
                    radius: 12,
                    backgroundColor: color == null ? Colors.grey : Color(color!)),
                onTap: () async {
                  final p = await pickColor(c, current: color);
                  if (p != null) setS(() => color = p);
                },
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final id = await guarded(
      context,
      () => engine.createRoom(
        name: name.text,
        description: desc.text,
        color: color,
        isPublic: isPublic,
      ),
    );
    if (id != null && context.mounted) {
      await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => RoomPage(roomId: id)));
    }
  }
}
