import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_engine/mesh_engine.dart';

import '../application/app_controller.dart';
import 'widgets/common.dart';
import 'widgets/engine_access.dart';

/// Room details, members and roles, invites. Every action is gated by the
/// permission matrix; the controls a role may not use are not shown, and the
/// engine re-checks (and every other device's reducer re-validates) anyway.
class RoomSettingsPage extends ConsumerWidget {
  const RoomSettingsPage({super.key, required this.roomId});
  final Uint8List roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = engineOf(ref);
    final state = engine?.roomState(roomId);
    if (engine == null || state == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Room not found')));
    }
    final me = engine.self.peerId;
    final theme = ref.watch(appControllerProvider.select((s) => s.theme));
    final myRole = state.roleOf(me);
    bool can(Permission p) => state.can(me, p);
    final stored = engine.roomStore.room(roomId);
    final members = state.members.values.toList()
      ..sort((a, b) => b.role.rank.compareTo(a.role.rank));

    return Scaffold(
      appBar: AppBar(title: const Text('Room settings')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Name'),
            subtitle: Text(state.name),
            trailing: can(Permission.manageRoom) ? const Icon(Icons.edit) : null,
            onTap: can(Permission.manageRoom)
                ? () async {
                    final v = await promptText(context, 'Room name', initial: state.name);
                    if (v != null && v.trim().isNotEmpty && context.mounted) {
                      await guarded(context, () => engine.updateRoom(roomId, name: v.trim()));
                    }
                  }
                : null,
          ),
          ListTile(
            title: const Text('Description'),
            subtitle: Text(state.description.isEmpty ? '(none)' : state.description),
            trailing: can(Permission.manageRoom) ? const Icon(Icons.edit) : null,
            onTap: can(Permission.manageRoom)
                ? () async {
                    final v = await promptText(context, 'Description',
                        initial: state.description, maxLength: 256, multiline: true);
                    if (v != null && context.mounted) {
                      await guarded(context, () => engine.updateRoom(roomId, description: v));
                    }
                  }
                : null,
          ),
          ListTile(
            title: const Text('Icon (emoji)'),
            subtitle: Text(state.icon.isEmpty ? '(none)' : state.icon),
            trailing: can(Permission.manageRoom) ? const Icon(Icons.edit) : null,
            onTap: can(Permission.manageRoom)
                ? () async {
                    final v = await promptText(context, 'Icon', initial: state.icon, maxLength: 4);
                    if (v != null && context.mounted) {
                      await guarded(context, () => engine.updateRoom(roomId, icon: v.trim()));
                    }
                  }
                : null,
          ),
          ListTile(
            title: const Text('Room colour (for everyone)'),
            trailing: CircleAvatar(
                radius: 12,
                backgroundColor: state.color == null ? Colors.grey : Color(state.color!)),
            onTap: can(Permission.manageRoom)
                ? () async {
                    final c = await pickColor(context, current: state.color);
                    if (c != null && context.mounted) {
                      await guarded(context, () => engine.updateRoom(roomId, color: c));
                    }
                  }
                : null,
          ),
          SwitchListTile(
            title: const Text('Public'),
            subtitle: const Text('Nearby people can join without an invite.'),
            value: state.isPublic,
            onChanged: can(Permission.manageRoom)
                ? (v) => guarded(context, () => engine.updateRoom(roomId, isPublic: v))
                : null,
          ),
          const Divider(),
          // Per-device appearance: only changes how THIS phone draws the room.
          ListTile(
            title: const Text('My colour for this room'),
            subtitle: const Text('Only on this device'),
            trailing: CircleAvatar(
              radius: 12,
              backgroundColor: theme.colorForRoom(state.roomIdHex) == null
                  ? Colors.grey
                  : Color(theme.colorForRoom(state.roomIdHex)!),
            ),
            onTap: () async {
              final c = await pickColor(context, current: theme.colorForRoom(state.roomIdHex));
              if (c != null) {
                ref
                    .read(appControllerProvider.notifier)
                    .setTheme(theme.withRoomColor(state.roomIdHex, c));
              }
            },
            onLongPress: () => ref
                .read(appControllerProvider.notifier)
                .setTheme(theme.withRoomColor(state.roomIdHex, null)),
          ),
          SwitchListTile(
            title: const Text('Mute notifications'),
            value: stored?.muted ?? false,
            onChanged: (v) => engine.muteRoom(roomId, muted: v),
          ),
          const Divider(),
          ListTile(
            title: Text('Members (${members.length})'),
            trailing: can(Permission.manageMembers)
                ? Wrap(children: [
                    IconButton(
                      tooltip: 'Invite (QR)',
                      icon: const Icon(Icons.qr_code),
                      onPressed: () async {
                        final inv = await guarded(context, () => engine.createRoomInvite(roomId));
                        if (inv != null && context.mounted) {
                          await showQrDialog(context, 'Invite to ${state.name}', inv.toText());
                        }
                      },
                    ),
                    IconButton(
                      tooltip: 'Send invite to a contact',
                      icon: const Icon(Icons.send_outlined),
                      onPressed: () => _sendInvite(context, engine, state),
                    ),
                    IconButton(
                      tooltip: 'Add contact',
                      icon: const Icon(Icons.person_add),
                      onPressed: () => _addContact(context, engine, state),
                    ),
                  ])
                : null,
          ),
          for (final m in members)
            ListTile(
              leading: PeerAvatar(engine.peers.get(m.identity.peerId)?.title ?? m.identity.shortId),
              title: Text(m.peerIdHex == engine.self.peerIdHex
                  ? 'You'
                  : engine.peers.get(m.identity.peerId)?.title ?? 'Peer ${m.identity.shortId}'),
              subtitle: Text(m.role.name),
              trailing: _memberMenu(context, engine, state, m),
            ),
          const Divider(),
          if (myRole != null && myRole != Role.owner)
            ListTile(
              leading: const Icon(Icons.exit_to_app),
              title: const Text('Leave room'),
              onTap: () async {
                if (await confirm(context, 'Leave room?',
                    'You will stop receiving messages from it.',
                    action: 'Leave', destructive: true)) {
                  if (!context.mounted) return;
                  final ok = await guarded(context, () => engine.leaveRoom(roomId).then((_) => true));
                  if (ok == true && context.mounted) Navigator.of(context).pop();
                }
              },
            ),
          if (can(Permission.deleteRoom))
            ListTile(
              leading: Icon(Icons.delete_forever, color: Theme.of(context).colorScheme.error),
              title: const Text('Delete room'),
              subtitle: const Text('Freezes it for every member.'),
              onTap: () async {
                if (await confirm(context, 'Delete room?',
                    'This cannot be undone and applies to all members.',
                    action: 'Delete', destructive: true)) {
                  if (!context.mounted) return;
                  await guarded(context, () => engine.deleteRoom(roomId));
                }
              },
            ),
          if (state.rejected.isNotEmpty)
            ExpansionTile(
              title: Text('${state.rejected.length} ignored changes'),
              subtitle: const Text('Changes that violated permissions'),
              children: [
                for (final r in state.rejected.take(20)) ListTile(dense: true, title: Text('$r')),
              ],
            ),
        ],
      ),
    );
  }

  Widget? _memberMenu(BuildContext context, MeshEngine engine, RoomState s, Member m) {
    final me = engine.self.peerId;
    if (m.peerIdHex == engine.self.peerIdHex || m.role == Role.owner) return null;
    final canRemove = s.can(me, Permission.manageMembers) &&
        (s.roleOf(me)?.rank ?? 0) > m.role.rank;
    final canRole = s.can(me, Permission.manageRoles);
    if (!canRemove && !canRole) return null;
    return PopupMenuButton<String>(
      onSelected: (v) async {
        if (v == 'promote') {
          await guarded(context, () => engine.setRole(roomId, m.identity.peerId, Role.admin));
        } else if (v == 'demote') {
          await guarded(context, () => engine.setRole(roomId, m.identity.peerId, Role.member));
        } else if (v == 'remove') {
          if (await confirm(context, 'Remove member?', 'They lose access to this room.',
              action: 'Remove', destructive: true)) {
            if (!context.mounted) return;
            await guarded(context, () => engine.removeMember(roomId, m.identity.peerId));
          }
        }
      },
      itemBuilder: (_) => [
        if (canRole && m.role == Role.member)
          const PopupMenuItem(value: 'promote', child: Text('Make admin')),
        if (canRole && m.role == Role.admin)
          const PopupMenuItem(value: 'demote', child: Text('Remove admin')),
        if (canRemove) const PopupMenuItem(value: 'remove', child: Text('Remove from room')),
      ],
    );
  }

  Future<void> _sendInvite(BuildContext context, MeshEngine engine, RoomState s) async {
    final candidates = engine.peers
        .all()
        .where((p) => !p.blocked && !s.isMember(p.identity.peerId))
        .toList();
    final pick = await showModalBottomSheet<StoredPeer>(
      context: context,
      builder: (c) => SafeArea(
        child: candidates.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No contacts to send to.'),
              )
            : ListView(shrinkWrap: true, children: [
                for (final p in candidates)
                  ListTile(
                    leading: PeerAvatar(p.title),
                    title: Text(p.title),
                    onTap: () => Navigator.pop(c, p),
                  ),
              ]),
      ),
    );
    if (pick == null || !context.mounted) return;
    await guarded(context, () async {
      final inv = await engine.createRoomInvite(roomId);
      await engine.sendInvite(inv, pick.identity);
    });
    if (context.mounted) toast(context, 'Invite sent to ${pick.title}');
  }

  Future<void> _addContact(BuildContext context, MeshEngine engine, RoomState s) async {
    final candidates = engine.peers
        .all()
        .where((p) => !p.blocked && !s.isMember(p.identity.peerId))
        .toList();
    final pick = await showModalBottomSheet<StoredPeer>(
      context: context,
      builder: (c) => SafeArea(
        child: candidates.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No other contacts. Use the QR invite instead.'),
              )
            : ListView(shrinkWrap: true, children: [
                for (final p in candidates)
                  ListTile(
                    leading: PeerAvatar(p.title),
                    title: Text(p.title),
                    onTap: () => Navigator.pop(c, p),
                  ),
              ]),
      ),
    );
    if (pick == null || !context.mounted) return;
    await guarded(context, () => engine.addMember(roomId, pick.identity));
  }
}
