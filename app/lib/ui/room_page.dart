import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_engine/mesh_engine.dart';

import '../application/app_controller.dart';
import 'chat_page.dart';
import 'room_settings_page.dart';
import 'theme_builder.dart';
import 'widgets/common.dart';
import 'widgets/engine_access.dart';

/// Channels of one room. Tapping a channel opens its chat.
class RoomPage extends ConsumerWidget {
  const RoomPage({super.key, required this.roomId});
  final Uint8List roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = engineOf(ref);
    final theme = ref.watch(appControllerProvider.select((s) => s.theme));
    final state = engine?.roomState(roomId);
    if (engine == null || state == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Room not found')));
    }
    final stored = engine.roomStore.room(roomId);
    final color = roomColor(context, theme, state.roomIdHex, state.color);
    final channels = engine.roomStore.channels(roomId);
    final canManage = state.can(engine.self.peerId, Permission.manageChannels);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: color.withValues(alpha: 0.25),
        title: Text('${state.icon} ${state.name}'.trim()),
        actions: [
          IconButton(
            tooltip: 'Room settings',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => RoomSettingsPage(roomId: roomId))),
          ),
        ],
      ),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () async {
                final n = await promptText(context, 'New channel', hint: 'name');
                if (n == null || n.trim().isEmpty || !context.mounted) return;
                await guarded(context, () => engine.addChannel(roomId, n.trim()));
              },
              icon: const Icon(Icons.add),
              label: const Text('Channel'),
            )
          : null,
      body: ListView(
        children: [
          if (state.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(state.description),
            ),
          if (state.deleted)
            const ListTile(
              leading: Icon(Icons.delete_forever),
              title: Text('This room was deleted by its owner.'),
            ),
          if (stored != null && !stored.active)
            const ListTile(
              leading: Icon(Icons.block),
              title: Text('You are no longer a member of this room.'),
            ),
          for (final c in channels)
            ListTile(
              leading: Icon(Icons.tag, color: c.color == null ? null : Color(c.color!)),
              title: Text(c.name),
              subtitle: c.description.isEmpty ? null : Text(c.description),
              trailing: Badge.count(
                count: engine.messages.unreadCount(ConvKind.channel, c.channelId),
                isLabelVisible:
                    engine.messages.unreadCount(ConvKind.channel, c.channelId) > 0,
              ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ChatPage(
                  kind: ConvKind.channel,
                  convId: c.channelId,
                  roomId: roomId,
                ),
              )),
              onLongPress: canManage
                  ? () => _channelMenu(context, engine, c)
                  : null,
            ),
        ],
      ),
    );
  }

  Future<void> _channelMenu(BuildContext context, MeshEngine engine, StoredChannel c) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('Colour'),
              onTap: () => Navigator.pop(ctx, 'color')),
          ListTile(
              leading: Icon(c.muted ? Icons.notifications : Icons.notifications_off),
              title: Text(c.muted ? 'Unmute (this device)' : 'Mute (this device)'),
              onTap: () => Navigator.pop(ctx, 'mute')),
          ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete channel'),
              onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'rename':
        final n = await promptText(context, 'Rename channel', initial: c.name);
        if (n != null && n.trim().isNotEmpty && context.mounted) {
          await guarded(context,
              () => engine.updateChannel(roomId, c.channelId, name: n.trim()));
        }
      case 'color':
        final col = await pickColor(context, current: c.color);
        if (col != null && context.mounted) {
          await guarded(context,
              () => engine.updateChannel(roomId, c.channelId, color: col));
        }
      case 'mute':
        engine.muteChannel(roomId, c.channelId, muted: !c.muted);
      case 'delete':
        if (await confirm(context, 'Delete channel?',
            'The channel disappears for all members.',
            action: 'Delete', destructive: true)) {
          if (!context.mounted) return;
          await guarded(context, () => engine.deleteChannel(roomId, c.channelId));
        }
    }
  }
}
