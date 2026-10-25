import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_engine/mesh_engine.dart';

import 'chat_page.dart';
import 'search_page.dart';
import 'widgets/common.dart';
import 'widgets/engine_access.dart';

class ChatsTab extends ConsumerWidget {
  const ChatsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = engineOf(ref);
    if (engine == null) return const Center(child: CircularProgressIndicator());

    final convs = [
      ...engine.messages.conversations(ConvKind.direct),
      ...engine.messages.conversations(ConvKind.channel),
    ]..sort((a, b) => b.last.ts.compareTo(a.last.ts));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SearchPage())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New chat',
        onPressed: () => _newChat(context, engine),
        child: const Icon(Icons.edit),
      ),
      body: convs.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No conversations yet.\nOpen Nearby to find devices, or '
                  'tap the pencil to message a contact.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              itemCount: convs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _ConversationTile(engine, convs[i]),
            ),
    );
  }

  Future<void> _newChat(BuildContext context, MeshEngine engine) async {
    final contacts = engine.peers.all().where((p) => !p.blocked).toList();
    final peer = await showModalBottomSheet<StoredPeer>(
      context: context,
      builder: (c) => SafeArea(
        child: contacts.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No contacts yet. Add one from Nearby.'),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final p in contacts)
                    ListTile(
                      leading: PeerAvatar(p.title),
                      title: Text(p.title),
                      subtitle: Text(p.identity.shortId),
                      onTap: () => Navigator.pop(c, p),
                    ),
                ],
              ),
      ),
    );
    if (peer == null || !context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChatPage(kind: ConvKind.direct, convId: peer.identity.peerId),
    ));
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile(this.engine, this.c);
  final MeshEngine engine;
  final ConversationSummary c;

  @override
  Widget build(BuildContext context) {
    String title;
    if (c.convKind == ConvKind.direct) {
      title = engine.peers.get(c.convId)?.title ?? 'Peer ${toHex(c.convId).substring(0, 8)}';
    } else {
      final roomId = c.last.roomId;
      final room = roomId == null ? null : engine.roomStore.room(roomId);
      final ch = roomId == null
          ? null
          : engine.roomStore
              .channels(roomId)
              .where((x) => toHex(x.channelId) == toHex(c.convId))
              .firstOrNull;
      title = '${room?.name ?? 'Room'} · #${ch?.name ?? 'channel'}';
    }
    final last = c.last;
    final preview = last.deleted ? 'message deleted' : last.text;
    return ListTile(
      leading: PeerAvatar(title),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${last.outgoing ? 'You: ' : ''}$preview',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: last.deleted ? const TextStyle(fontStyle: FontStyle.italic) : null,
      ),
      trailing: c.unread > 0
          ? Badge(label: Text('${c.unread}'))
          : null,
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChatPage(
          kind: c.convKind,
          convId: c.convId,
          roomId: last.roomId,
        ),
      )),
    );
  }
}
