import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_engine/mesh_engine.dart';

import 'widgets/common.dart';
import 'widgets/engine_access.dart';

/// A direct chat (kind = direct, convId = peer) or a room channel
/// (kind = channel, convId = channel, roomId = room).
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({
    super.key,
    required this.kind,
    required this.convId,
    this.roomId,
  });
  final ConvKind kind;
  final Uint8List convId;
  final Uint8List? roomId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  StoredMessage? _replyTo;
  StoredMessage? _editing;
  int _lastCount = -1;

  static const _quickReactions = ['👍', '❤️', '😂', '😮', '🙏'];

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _isDirect => widget.kind == ConvKind.direct;

  Future<void> _send(MeshEngine engine) async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final editing = _editing;
    final reply = _replyTo;
    _input.clear();
    setState(() {
      _editing = null;
      _replyTo = null;
    });
    await guarded(context, () async {
      if (editing != null) {
        await engine.editMessage(editing, text);
      } else if (_isDirect) {
        final peer = engine.directory.lookup(widget.convId);
        if (peer == null) throw const NotFoundException('Unknown contact');
        await engine.sendDirect(peer, text, replyTo: reply?.msgId);
      } else {
        await engine.sendRoomMessage(widget.roomId!, widget.convId, text,
            replyTo: reply?.msgId);
      }
    });
  }

  Future<void> _actions(MeshEngine engine, StoredMessage m) async {
    if (m.deleted) return;
    final canModerate = !m.outgoing &&
        widget.roomId != null &&
        (engine.roomState(widget.roomId!)?.canDeleteMessage(engine.self.peerId, m.sender) ??
            false);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(spacing: 4, children: [
                for (final e in _quickReactions)
                  TextButton(
                    onPressed: () => Navigator.pop(c, 'react:$e'),
                    child: Text(e, style: const TextStyle(fontSize: 24)),
                  ),
              ]),
            ),
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () => Navigator.pop(c, 'reply'),
            ),
            if (m.outgoing)
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Edit'),
                onTap: () => Navigator.pop(c, 'edit'),
              ),
            if (m.outgoing || canModerate)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(m.outgoing ? 'Delete for everyone' : 'Delete (moderator)'),
                onTap: () => Navigator.pop(c, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice.startsWith('react:')) {
      final emoji = choice.substring(6);
      final mine = engine.messages
              .reactions(m.msgId)[emoji]
              ?.contains(toHex(engine.self.peerId)) ??
          false;
      await guarded(context, () => engine.react(m, emoji, add: !mine));
    } else if (choice == 'reply') {
      setState(() => _replyTo = m);
    } else if (choice == 'edit') {
      setState(() {
        _editing = m;
        _input.text = m.text;
      });
    } else if (choice == 'delete') {
      if (await confirm(context, 'Delete message?',
          'It will be removed for everyone in this conversation.',
          action: 'Delete', destructive: true)) {
        if (!mounted) return;
        await guarded(context, () => engine.deleteMessage(m));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = engineOf(ref);
    if (engine == null) return const Scaffold(body: SizedBox());
    final msgs = engine.messages.list(widget.kind, widget.convId);

    // Opening / receiving while visible marks the conversation read.
    if (engine.messages.unreadCount(widget.kind, widget.convId) > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        engine.markRead(widget.kind, widget.convId);
      });
    }
    if (msgs.length != _lastCount) {
      _lastCount = msgs.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }

    final String title;
    bool canPost = true;
    String? banner;
    if (_isDirect) {
      final p = engine.peers.get(widget.convId);
      title = p?.title ?? 'Peer ${toHex(widget.convId).substring(0, 8)}';
      if (p != null && p.blocked) {
        canPost = false;
        banner = 'You blocked this contact.';
      }
    } else {
      final state = engine.roomState(widget.roomId!);
      final ch = state?.channels[toHex(widget.convId)];
      title = '${state?.name ?? 'Room'} · #${ch?.name ?? ''}';
      canPost = state?.canSend(engine.self.peerId, widget.convId) ?? false;
      if (!canPost) banner = 'You cannot post in this channel.';
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: _isDirect ? _directActions(engine) : null,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: msgs.length,
              itemBuilder: (_, i) => _Bubble(
                engine: engine,
                m: msgs[i],
                showSender: !_isDirect,
                byId: {for (final x in msgs) x.idHex: x},
                onLongPress: () => _actions(engine, msgs[i]),
              ),
            ),
          ),
          if (banner != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(banner, textAlign: TextAlign.center),
            ),
          if (_replyTo != null || _editing != null)
            ListTile(
              dense: true,
              leading: Icon(_editing != null ? Icons.edit : Icons.reply),
              title: Text(
                utf8Clip((_editing ?? _replyTo)!.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _editing = null;
                  _replyTo = null;
                  _input.clear();
                }),
              ),
            ),
          if (canPost)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(engine),
                        decoration: const InputDecoration(
                            hintText: 'Message', border: OutlineInputBorder()),
                      ),
                    ),
                    IconButton(
                        onPressed: () => _send(engine),
                        icon: const Icon(Icons.send)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String utf8Clip(String s) => s.length > 80 ? '${s.substring(0, 80)}…' : s;

  List<Widget> _directActions(MeshEngine engine) {
    final p = engine.peers.get(widget.convId);
    if (p == null) return const [];
    return [
      IconButton(
        tooltip: p.verified ? 'Verified' : 'Verify identity',
        icon: Icon(p.verified ? Icons.verified_user : Icons.verified_user_outlined),
        onPressed: () => showFingerprintDialog(
          context,
          identity: p.identity,
          verified: p.verified,
          onVerified: (v) => engine.verifyPeer(p.identity.peerId, verified: v),
        ),
      ),
      PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'mute') engine.mutePeer(p.identity.peerId, muted: !p.muted);
          if (v == 'block') engine.blockPeer(p.identity.peerId, blocked: !p.blocked);
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'mute', child: Text(p.muted ? 'Unmute' : 'Mute')),
          PopupMenuItem(value: 'block', child: Text(p.blocked ? 'Unblock' : 'Block')),
        ],
      ),
    ];
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.engine,
    required this.m,
    required this.showSender,
    required this.byId,
    required this.onLongPress,
  });
  final MeshEngine engine;
  final StoredMessage m;
  final bool showSender;
  final Map<String, StoredMessage> byId;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reactions = engine.messages.reactions(m.msgId);
    final replied = m.replyTo == null ? null : byId[toHex(m.replyTo!)];
    final senderName = m.outgoing
        ? 'You'
        : engine.peers.get(m.sender)?.title ?? 'Peer ${toHex(m.sender).substring(0, 8)}';
    return Align(
      alignment: m.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.8),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: m.outgoing ? scheme.primaryContainer : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSender && !m.outgoing)
                Text(senderName,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: scheme.primary)),
              if (replied != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.only(left: 6),
                  decoration: BoxDecoration(
                      border: Border(left: BorderSide(color: scheme.primary, width: 2))),
                  child: Text(
                    replied.deleted ? 'message deleted' : replied.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (m.deleted)
                const Text('message deleted',
                    style: TextStyle(fontStyle: FontStyle.italic))
              else if (Invite.tryFromText(m.text) != null)
                _InviteCard(engine: engine, text: m.text, mine: m.outgoing)
              else
                Text(m.text),
              if (reactions.isNotEmpty)
                Wrap(spacing: 4, children: [
                  for (final e in reactions.entries)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text('${e.key} ${e.value.length}'),
                    ),
                ]),
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (m.edited && !m.deleted)
                    Text('edited ',
                        style: Theme.of(context).textTheme.labelSmall),
                  if (m.outgoing) StatusTick(m.status),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// A chat message that carries a signed invite: shows what it is and, for the
/// recipient, a button to accept it.
class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.engine, required this.text, required this.mine});
  final MeshEngine engine;
  final String text;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final inv = Invite.tryFromText(text)!;
    final label = inv.kind == InviteKind.room
        ? 'Invitation to room "${inv.roomName ?? ''}"'
        : 'Contact card of ${inv.name.isEmpty ? 'someone' : inv.name}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.mail_outline, size: 18),
          const SizedBox(width: 6),
          Flexible(child: Text(label)),
        ]),
        if (!mine)
          TextButton(
            onPressed: () async {
              final who = await guarded(context, () => engine.redeemInvite(text));
              if (who != null && context.mounted) {
                toast(context, 'Invite accepted');
              }
            },
            child: Text(inv.kind == InviteKind.room ? 'Join' : 'Add contact'),
          ),
      ],
    );
  }
}
