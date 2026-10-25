part of 'engine.dart';

/// Direct and room chat operations: send, edit, delete, react, read receipts,
/// and processing of incoming chat content.
extension MeshEngineChat on MeshEngine {
  // ─────────────────────────────── sending ───────────────────────────────

  /// Queues an end-to-end encrypted direct message. It is stored immediately
  /// (status [MsgStatus.queued]) and sent as soon as a route exists; the
  /// outbox keeps retrying across restarts until it is acknowledged or expires.
  Future<StoredMessage> sendDirect(
    PeerIdentity peer,
    String text, {
    Uint8List? replyTo,
  }) async {
    final body = _validText(text);
    if (peer.peerIdHex == self.peerIdHex) {
      throw ArgumentError('Cannot message yourself');
    }
    peers.upsert(peer);
    directory.remember(peer);
    final id = randomBytes(kIdLength);
    final m = StoredMessage(
      msgId: id,
      sender: self.peerId,
      convKind: ConvKind.direct,
      convId: peer.peerId,
      text: body,
      replyTo: replyTo,
      ts: now(),
      outgoing: true,
    );
    messages.insert(m);
    _enqueue(
      dest: peer.peerId,
      content: MessageContent.text(body, replyTo: replyTo),
      msgId: id,
      tracked: true,
    );
    _emit(MessagesChanged(ConvKind.direct, peer.peerId));
    unawaited(flushOutbox());
    return m;
  }

  String _validText(String text) {
    final body = text.trim();
    if (body.isEmpty) throw ArgumentError('Empty message');
    if (body.length > MessageContent.maxTextChars) {
      throw ArgumentError('Message too long');
    }
    return body;
  }

  /// Recipients of operations on [m]: the other party, or the other room
  /// members.
  List<PeerIdentity> _audience(StoredMessage m) {
    if (m.convKind == ConvKind.direct) {
      final p = directory.lookup(m.convId);
      return p == null ? const [] : [p];
    }
    final log = _logs[toHex(m.roomId ?? m.convId)];
    if (log == null) return const [];
    return [
      for (final mem in log.state.members.values)
        if (mem.peerIdHex != self.peerIdHex) mem.identity,
    ];
  }

  void _sendToAudience(StoredMessage m, MessageContent content) {
    for (final p in _audience(m)) {
      _enqueue(dest: p.peerId, content: content, roomId: m.roomId);
    }
    unawaited(flushOutbox());
  }

  /// Edits one of OUR messages (locally and for every recipient).
  Future<void> editMessage(StoredMessage m, String newText) async {
    if (!m.outgoing || m.deleted) {
      throw const PermissionDeniedException(
          'Only your own messages can be edited');
    }
    final body = _validText(newText);
    if (!messages.applyEdit(m.msgId, m.sender, body)) {
      throw const NotFoundException('Message not found');
    }
    _sendToAudience(
      m,
      MessageContent.edit(m.msgId, body,
          channelId: m.convKind == ConvKind.channel ? m.convId : null),
    );
    _emit(MessagesChanged(m.convKind, m.convId));
  }

  /// Deletes a message for everyone. Authors may delete their own; in rooms,
  /// members with the deleteMessages permission may delete others'.
  Future<void> deleteMessage(StoredMessage m) async {
    if (!m.outgoing) {
      final log = m.roomId == null ? null : _logs[toHex(m.roomId!)];
      if (log == null || !log.state.canDeleteMessage(self.peerId, m.sender)) {
        throw const PermissionDeniedException('You cannot delete this message');
      }
    }
    if (!messages.applyDelete(m.msgId, m.sender)) {
      throw const NotFoundException('Message not found');
    }
    _sendToAudience(
      m,
      MessageContent.delete(m.msgId,
          channelId: m.convKind == ConvKind.channel ? m.convId : null),
    );
    _emit(MessagesChanged(m.convKind, m.convId));
  }

  /// Adds (or removes) our reaction to [m].
  Future<void> react(StoredMessage m, String emoji, {bool add = true}) async {
    if (m.deleted) return;
    if (emoji.isEmpty || emoji.length > 16) throw ArgumentError('Bad emoji');
    if (add) {
      messages.addReaction(m.msgId, self.peerId, emoji);
    } else {
      messages.removeReaction(m.msgId, self.peerId, emoji);
    }
    _sendToAudience(
      m,
      MessageContent.reaction(m.msgId, emoji,
          add: add,
          channelId: m.convKind == ConvKind.channel ? m.convId : null),
    );
    _emit(MessagesChanged(m.convKind, m.convId));
  }

  /// Marks a conversation read locally and, for direct chats and if enabled in
  /// settings, tells the sender (a verified receipt is the only way a message
  /// ever shows "read").
  Future<void> markRead(ConvKind kind, Uint8List convId) async {
    final read = messages.markConversationRead(kind, convId);
    if (read.isEmpty) return;
    _emit(MessagesChanged(kind, convId));
    if (kind != ConvKind.direct) return;
    if (!settings.getBool('read_receipts', fallback: true)) return;
    final peer = directory.lookup(convId);
    if (peer == null) return;
    final ids = [for (final m in read) m.msgId];
    for (var i = 0; i < ids.length; i += MessageContent.maxBlobs) {
      final chunk =
          ids.sublist(i, (i + MessageContent.maxBlobs).clamp(0, ids.length));
      _enqueue(dest: peer.peerId, content: MessageContent.read(chunk));
    }
    unawaited(flushOutbox());
  }

  // ───────────────────────────── incoming ────────────────────────────────

  Future<void> _onIncoming(OpenedMessage m) async {
    if (m.content.kind >= 10) {
      await _onControl(m);
      return;
    }
    final roomId = m.roomId;
    if (roomId == null) {
      _onDirect(m);
    } else {
      _onRoomChat(m, roomId);
    }
  }

  void _onDirect(OpenedMessage m) {
    final c = m.content;
    final sender = m.sender.peerId;
    switch (c.kind) {
      case MessageContent.kindText:
        final stored = StoredMessage(
          msgId: m.messageId,
          sender: sender,
          convKind: ConvKind.direct,
          convId: sender,
          text: c.text,
          replyTo: c.replyTo,
          ts: m.timestampMs,
          outgoing: false,
          status: MsgStatus.delivered,
          unread: true,
        );
        if (messages.insert(stored)) {
          _emit(MessagesChanged(ConvKind.direct, sender));
          _notify(
            muted: peers.isMuted(sender),
            title: peers.get(sender)?.title ?? 'New message',
            body: c.text,
            kind: ConvKind.direct,
            convId: sender,
          );
        }
      case MessageContent.kindReaction:
        final target = _findIn(c.targetId!, ConvKind.direct, sender);
        if (target == null) return;
        if (c.add) {
          messages.addReaction(target.msgId, sender, c.text);
        } else {
          messages.removeReaction(target.msgId, sender, c.text);
        }
        _emit(MessagesChanged(ConvKind.direct, sender));
      case MessageContent.kindEdit:
        // Only messages authored by the sender, inside their conversation.
        final own = messages.get(c.targetId!, sender);
        if (own != null &&
            own.convKind == ConvKind.direct &&
            messages.applyEdit(c.targetId!, sender, _clip(c.text))) {
          _emit(MessagesChanged(ConvKind.direct, sender));
        }
      case MessageContent.kindDelete:
        final own = messages.get(c.targetId!, sender);
        if (own != null &&
            own.convKind == ConvKind.direct &&
            messages.applyDelete(c.targetId!, sender)) {
          _emit(MessagesChanged(ConvKind.direct, sender));
        }
      case MessageContent.kindRead:
        for (final id in c.blobs) {
          final mine = messages.get(id, self.peerId);
          if (mine != null &&
              mine.outgoing &&
              mine.convKind == ConvKind.direct &&
              toHex(mine.convId) == m.sender.peerIdHex) {
            messages.markReadByRecipient(id);
            _emit(MessageStatusChanged(id));
          }
        }
    }
  }

  void _onRoomChat(OpenedMessage m, Uint8List roomId) {
    final log = _logs[toHex(roomId)];
    if (log == null) return;
    final state = log.state;
    final sender = m.sender.peerId;
    if (!state.isMember(self.peerId) || !state.isMember(sender)) return;
    final c = m.content;
    final channelId = c.channelId;

    switch (c.kind) {
      case MessageContent.kindText:
        if (channelId == null || !state.canSend(sender, channelId)) return;
        final stored = StoredMessage(
          msgId: m.messageId,
          sender: sender,
          convKind: ConvKind.channel,
          convId: channelId,
          roomId: roomId,
          text: c.text,
          replyTo: c.replyTo,
          ts: m.timestampMs,
          outgoing: false,
          status: MsgStatus.delivered,
          unread: true,
        );
        if (messages.insert(stored)) {
          _emit(MessagesChanged(ConvKind.channel, channelId));
          final ch = state.channels[toHex(channelId)];
          _notify(
            muted: roomStore.isChannelMuted(channelId) ||
                peers.isMuted(sender) ||
                (roomStore.room(roomId)?.muted ?? false),
            title: '${state.name} · #${ch?.name ?? ''}',
            body: '${m.sender.shortId}: ${c.text}',
            kind: ConvKind.channel,
            convId: channelId,
          );
        }
      case MessageContent.kindReaction:
        final target = _roomMessage(c.targetId!, roomId);
        if (target == null) return;
        if (c.add) {
          messages.addReaction(target.msgId, sender, c.text);
        } else {
          messages.removeReaction(target.msgId, sender, c.text);
        }
        _emit(MessagesChanged(ConvKind.channel, target.convId));
      case MessageContent.kindEdit:
        final target = messages.get(c.targetId!, sender);
        if (target != null &&
            target.roomId != null &&
            toHex(target.roomId!) == toHex(roomId) &&
            messages.applyEdit(c.targetId!, sender, _clip(c.text))) {
          _emit(MessagesChanged(ConvKind.channel, target.convId));
        }
      case MessageContent.kindDelete:
        final target = _roomMessage(c.targetId!, roomId);
        if (target == null) return;
        // Author, or a moderator at the position of the current state.
        if (state.canDeleteMessage(sender, target.sender) &&
            messages.applyDelete(target.msgId, target.sender)) {
          _emit(MessagesChanged(ConvKind.channel, target.convId));
        }
      case MessageContent.kindRead:
        break; // read receipts are direct-chat only
    }
  }

  static String _clip(String s) => s.length > MessageContent.maxTextChars
      ? s.substring(0, MessageContent.maxTextChars)
      : s;

  StoredMessage? _findIn(Uint8List msgId, ConvKind kind, Uint8List convId) {
    for (final m in messages.byId(msgId)) {
      if (m.convKind == kind && toHex(m.convId) == toHex(convId)) return m;
    }
    return null;
  }

  StoredMessage? _roomMessage(Uint8List msgId, Uint8List roomId) {
    for (final m in messages.byId(msgId)) {
      if (m.roomId != null && toHex(m.roomId!) == toHex(roomId)) return m;
    }
    return null;
  }

  void _notify({
    required bool muted,
    required String title,
    required String body,
    required ConvKind kind,
    required Uint8List convId,
  }) {
    if (muted || !settings.getBool('notifications', fallback: true)) return;
    _emit(IncomingNotification(
      title: title,
      body: body.length > 120 ? '${body.substring(0, 120)}…' : body,
      kind: kind,
      convId: convId,
    ));
  }

  // ───────────────────── contacts, block/mute, search ────────────────────

  void blockPeer(Uint8List peerId, {bool blocked = true}) {
    peers.setBlocked(peerId, blocked);
    _emit(const PeersChanged());
  }

  void mutePeer(Uint8List peerId, {bool muted = true}) {
    peers.setMuted(peerId, muted);
    _emit(const PeersChanged());
  }

  /// Marks a contact as verified after the user compared fingerprints.
  void verifyPeer(Uint8List peerId, {bool verified = true}) {
    peers.setVerified(peerId, verified);
    _emit(const PeersChanged());
  }

  void muteRoom(Uint8List roomId, {bool muted = true}) {
    roomStore.setRoomMuted(roomId, muted);
    _emit(RoomsChanged(roomId));
  }

  void muteChannel(Uint8List roomId, Uint8List channelId, {bool muted = true}) {
    roomStore.setChannelMuted(roomId, channelId, muted);
    _emit(RoomsChanged(roomId));
  }

  /// Search over local data only: contacts, rooms/channels, message text.
  SearchResults search(String query) => SearchResults(
        peers.search(query),
        roomStore.search(query),
        messages.search(query),
      );
}
