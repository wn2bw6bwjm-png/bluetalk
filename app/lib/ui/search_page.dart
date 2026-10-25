import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_engine/mesh_engine.dart';

import 'chat_page.dart';
import 'room_page.dart';
import 'widgets/common.dart';
import 'widgets/engine_access.dart';

/// Search over local data only: contacts, rooms/channels, message text.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = engineOf(ref);
    final results = (engine == null || _q.text.trim().isEmpty)
        ? null
        : engine.search(_q.text);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _q,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'Search people, rooms, messages', border: InputBorder.none),
          onChanged: (_) => setState(() {}),
        ),
      ),
      body: results == null
          ? const Center(child: Text('Searches only data stored on this device.'))
          : results.isEmpty
              ? const Center(child: Text('Nothing found.'))
              : ListView(children: [
                  for (final p in results.peers)
                    ListTile(
                      leading: PeerAvatar(p.title),
                      title: Text(p.title),
                      subtitle: Text(p.identity.shortId),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => ChatPage(kind: ConvKind.direct, convId: p.identity.peerId))),
                    ),
                  for (final (room, channel) in results.rooms)
                    ListTile(
                      leading: Icon(channel == null ? Icons.groups : Icons.tag),
                      title: Text(channel == null ? room.name : '${room.name} · #${channel.name}'),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => channel == null
                              ? RoomPage(roomId: room.roomId)
                              : ChatPage(kind: ConvKind.channel, convId: channel.channelId, roomId: room.roomId))),
                    ),
                  for (final h in results.messages)
                    ListTile(
                      leading: const Icon(Icons.message_outlined),
                      title: Text(h.snippet),
                      subtitle: Text(_where(engine!, h.message)),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => ChatPage(
                                kind: h.message.convKind,
                                convId: h.message.convId,
                                roomId: h.message.roomId,
                              ))),
                    ),
                ]),
    );
  }

  String _where(MeshEngine engine, StoredMessage m) {
    if (m.convKind == ConvKind.direct) {
      return engine.peers.get(m.convId)?.title ?? 'Direct chat';
    }
    final room = m.roomId == null ? null : engine.roomStore.room(m.roomId!);
    return room?.name ?? 'Room';
  }
}
