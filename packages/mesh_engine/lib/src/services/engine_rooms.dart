part of 'engine.dart';

/// Rooms, channels, members, invites, and event synchronisation.
///
/// Every change is a signed [RoomEvent] appended to the room's log. Events are
/// delivered to members as end-to-end encrypted control messages (relays see
/// nothing), retried through the persistent outbox, and reconciled by an
/// anti-entropy exchange whenever two members connect.
extension MeshEngineRooms on MeshEngine {
  // ───────────────────────────── read access ─────────────────────────────

  RoomState? roomState(Uint8List roomId) => _logs[toHex(roomId)]?.state;

  Iterable<NearbyRoom> get nearbyRooms => _nearbyRooms.values;

  RoomLog _logOrThrow(Uint8List roomId) {
    final log = _logs[toHex(roomId)];
    if (log == null || !log.state.exists) {
      throw const NotFoundException('Unknown room');
    }
    return log;
  }

  void _loadRooms() {
    for (final id in roomStore.roomIds()) {
      final log = RoomLog(id);
      for (final e in roomStore.loadEvents(id)) {
        log.addTrusted(e); // verified when first stored
      }
      _logs[toHex(id)] = log;
    }
  }

  List<RoomAdvert> _publicRoomAdverts() {
    final out = <RoomAdvert>[];
    for (final log in _logs.values) {
      final s = log.state;
      final role = s.roleOf(self.peerId);
      if (s.exists &&
          !s.deleted &&
          s.isPublic &&
          (role == Role.owner || role == Role.admin)) {
        out.add(RoomAdvert(s.roomId, s.name));
      }
      if (out.length >= SessionService.maxAdverts) break;
    }
    return out;
  }

  void _noteAdverts(PeerIdentity via, List<RoomAdvert> adverts) {
    var changed = false;
    final before = _nearbyRooms.length;
    _nearbyRooms.removeWhere((_, r) => r.via.peerIdHex == via.peerIdHex);
    if (before != _nearbyRooms.length) changed = true;
    for (final a in adverts) {
      final already =
          _logs[toHex(a.roomId)]?.state.isMember(self.peerId) ?? false;
      if (already || a.name.isEmpty) continue;
      _nearbyRooms[toHex(a.roomId)] = NearbyRoom(a.roomId, a.name, via);
      changed = true;
    }
    if (changed) _emit(const NearbyRoomsChanged());
  }

  // ─────────────────────────── creating / editing ────────────────────────

  Future<Uint8List> createRoom({
    required String name,
    String description = '',
    String icon = '',
    int? color,
    bool isPublic = false,
    String? firstChannel = 'general',
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('Room needs a name');
    final author = await RoomAuthor.createRoom(
      identity,
      name: name.trim(),
      description: description,
      icon: icon,
      color: color,
      isPublic: isPublic,
      firstChannel: firstChannel,
    );
    _logs[toHex(author.log.roomId)] = author.log;
    await _afterLocalChange(author.log, author.log.events.toList(), const []);
    return author.log.roomId;
  }

  /// A group chat is a private room with one channel and the given members.
  Future<Uint8List> createGroup(String name, List<PeerIdentity> members) async {
    final id = await createRoom(name: name, firstChannel: 'general');
    for (final m in members) {
      await addMember(id, m);
    }
    return id;
  }

  Future<void> _act(
    Uint8List roomId,
    Permission? need,
    Future<List<RoomEvent>> Function(RoomAuthor) body, {
    List<PeerIdentity> extra = const [],
  }) async {
    final log = _logOrThrow(roomId);
    if (need != null && !log.state.can(self.peerId, need)) {
      throw PermissionDeniedException('Missing permission: ${need.name}');
    }
    final before = [for (final m in log.state.members.values) m.identity];
    final events = await body(RoomAuthor(identity, log));
    await _afterLocalChange(log, events, before, extra: extra);
  }

  Future<void> updateRoom(
    Uint8List roomId, {
    String? name,
    String? description,
    String? icon,
    int? color,
    bool? isPublic,
  }) =>
      _act(
          roomId,
          Permission.manageRoom,
          (a) async => [
                await a.update(
                  name: name,
                  description: description,
                  icon: icon,
                  color: color,
                  isPublic: isPublic,
                ),
              ]);

  Future<void> deleteRoom(Uint8List roomId) =>
      _act(roomId, Permission.deleteRoom, (a) async => [await a.deleteRoom()]);

  Future<Uint8List> addChannel(
    Uint8List roomId,
    String name, {
    String description = '',
    String icon = '',
    int? color,
  }) async {
    late Uint8List id;
    await _act(roomId, Permission.manageChannels, (a) async {
      final e = await a.addChannel(name,
          description: description, icon: icon, color: color);
      id = Uint8List.fromList((e.data[K.channelId] as List).cast<int>());
      return [e];
    });
    return id;
  }

  Future<void> updateChannel(
    Uint8List roomId,
    Uint8List channelId, {
    String? name,
    String? description,
    String? icon,
    int? color,
  }) =>
      _act(
          roomId,
          Permission.manageChannels,
          (a) async => [
                await a.updateChannel(channelId,
                    name: name,
                    description: description,
                    icon: icon,
                    color: color),
              ]);

  Future<void> deleteChannel(Uint8List roomId, Uint8List channelId) => _act(
      roomId,
      Permission.manageChannels,
      (a) async => [await a.deleteChannel(channelId)]);

  Future<void> addMember(
    Uint8List roomId,
    PeerIdentity who, {
    Role role = Role.member,
  }) async {
    final log = _logOrThrow(roomId);
    final need =
        role == Role.admin ? Permission.manageRoles : Permission.manageMembers;
    if (!log.state.can(self.peerId, need)) {
      throw PermissionDeniedException('Missing permission: ${need.name}');
    }
    peers.upsert(who);
    directory.remember(who);
    await _act(roomId, Permission.manageMembers,
        (a) async => [await a.addMember(who, role: role)]);
    // The newcomer needs the whole history of events, not just this one.
    await _sendEvents(roomId, who, log.events.toList());
  }

  Future<void> removeMember(Uint8List roomId, Uint8List peerId) =>
      _act(roomId, null, (a) async => [await a.removeMember(peerId)]);

  Future<void> setRole(Uint8List roomId, Uint8List peerId, Role role) => _act(
      roomId,
      Permission.manageRoles,
      (a) async => [await a.setRole(peerId, role)]);

  Future<void> leaveRoom(Uint8List roomId) =>
      _act(roomId, null, (a) async => [await a.leave()]);

  // ─────────────────────────── room messaging ────────────────────────────

  /// Sends a message to a channel: one end-to-end encrypted copy per member,
  /// each tracked separately; the message is "delivered" once all acked.
  Future<StoredMessage> sendRoomMessage(
    Uint8List roomId,
    Uint8List channelId,
    String text, {
    Uint8List? replyTo,
  }) async {
    final log = _logOrThrow(roomId);
    final state = log.state;
    if (!state.canSend(self.peerId, channelId)) {
      throw const PermissionDeniedException('You cannot post in this channel');
    }
    final body = _validText(text);
    final id = randomBytes(kIdLength);
    final recipients = [
      for (final m in state.members.values)
        if (m.peerIdHex != self.peerIdHex) m.identity,
    ];
    final m = StoredMessage(
      msgId: id,
      sender: self.peerId,
      convKind: ConvKind.channel,
      convId: channelId,
      roomId: roomId,
      text: body,
      replyTo: replyTo,
      ts: now(),
      outgoing: true,
      // Alone in the room: nothing to deliver.
      status: recipients.isEmpty ? MsgStatus.sent : MsgStatus.queued,
    );
    messages.insert(m);
    for (final r in recipients) {
      directory.remember(r);
      _enqueue(
        dest: r.peerId,
        content:
            MessageContent.text(body, replyTo: replyTo, channelId: channelId),
        msgId: id,
        roomId: roomId,
        tracked: true,
      );
    }
    _emit(MessagesChanged(ConvKind.channel, channelId));
    unawaited(flushOutbox());
    return m;
  }

  // ──────────────────────────────── invites ──────────────────────────────

  Future<Invite> createContactInvite(
          {Duration validFor = const Duration(days: 7)}) =>
      Invite.create(
        issuer: identity,
        kind: InviteKind.contact,
        name: displayName ?? '',
        validFor: validFor,
        nowMs: now(),
      );

  Future<Invite> createRoomInvite(
    Uint8List roomId, {
    Duration validFor = const Duration(hours: 24),
  }) async {
    final log = _logOrThrow(roomId);
    if (!log.state.can(self.peerId, Permission.manageMembers)) {
      throw const PermissionDeniedException(
          'Missing permission: manageMembers');
    }
    return Invite.create(
      issuer: identity,
      kind: InviteKind.room,
      name: displayName ?? '',
      validFor: validFor,
      roomId: roomId,
      roomName: log.state.name,
      nowMs: now(),
    );
  }

  /// Hands an invite to a contact over the mesh (the "nearby connection"
  /// route): it travels as an ordinary end-to-end encrypted message, and the
  /// recipient's chat offers a button to accept it.
  Future<StoredMessage> sendInvite(Invite invite, PeerIdentity to) =>
      sendDirect(to, invite.toText());

  /// Accepts a scanned/pasted invite. Contact invites add the contact; room
  /// invites also ask the issuer (over the mesh, retried through the outbox)
  /// to add us. Throws on forged, malformed or expired invites.
  Future<PeerIdentity> redeemInvite(String text) async {
    final inv = Invite.fromText(text);
    final issuer = await inv.verify(nowMs: now());
    if (issuer.peerIdHex == self.peerIdHex) {
      throw ArgumentError('This is your own invite');
    }
    peers.upsert(issuer, name: inv.name.isEmpty ? null : inv.name);
    directory.remember(issuer);
    if (inv.kind == InviteKind.room) {
      final roomHex = toHex(inv.roomId!);
      _pendingJoins[roomHex] = issuer.peerIdHex;
      _enqueue(
        dest: issuer.peerId,
        roomId: inv.roomId,
        content: MessageContent.control(
          MessageContent.kindJoinRequest,
          blobs: [inv.toBytes()],
        ),
      );
      unawaited(flushOutbox());
    }
    _emit(const PeersChanged());
    return issuer;
  }

  /// Join a public room offered by a nearby peer.
  Future<void> joinPublicRoom(NearbyRoom room) async {
    _pendingJoins[toHex(room.roomId)] = room.via.peerIdHex;
    _enqueue(
      dest: room.via.peerId,
      roomId: room.roomId,
      content: const MessageContent.control(MessageContent.kindJoinRequest),
    );
    unawaited(flushOutbox());
  }

  // ───────────────────────── distribution & sync ─────────────────────────

  Future<void> _afterLocalChange(
    RoomLog log,
    List<RoomEvent> events,
    List<PeerIdentity> before, {
    List<PeerIdentity> extra = const [],
  }) async {
    final state = log.state;
    roomStore.saveEvents(events);
    roomStore.materialize(state, self.peerId, now());
    for (final m in state.members.values) {
      directory.remember(m.identity);
    }
    _emit(RoomsChanged(log.roomId));

    final recipients = <String, PeerIdentity>{};
    for (final p in [
      ...before,
      ...extra,
      for (final m in state.members.values) m.identity,
    ]) {
      if (p.peerIdHex != self.peerIdHex) recipients[p.peerIdHex] = p;
    }
    for (final p in recipients.values) {
      await _sendEvents(log.roomId, p, events, flush: false);
    }
    unawaited(flushOutbox());
  }

  /// Batches [events] into control messages (size- and count-bounded).
  Future<void> _sendEvents(
    Uint8List roomId,
    PeerIdentity to,
    List<RoomEvent> events, {
    bool flush = true,
  }) async {
    const maxBatchBytes = 8000;
    final sorted = [...events]..sort(RoomEvent.compare);
    var batch = <Uint8List>[];
    var size = 0;
    void emitBatch() {
      if (batch.isEmpty) return;
      _enqueue(
        dest: to.peerId,
        roomId: roomId,
        content: MessageContent.control(MessageContent.kindRoomEvents,
            blobs: List.of(batch)),
      );
      batch = [];
      size = 0;
    }

    for (final e in sorted) {
      final b = e.encode();
      if (batch.length >= MessageContent.maxBlobs ||
          size + b.length > maxBatchBytes) {
        emitBatch();
      }
      batch.add(b);
      size += b.length;
    }
    emitBatch();
    if (flush) unawaited(flushOutbox());
  }

  static const int _maxOfferIds = 600;

  Uint8List _packIds(Iterable<Uint8List> ids) =>
      Uint8List.fromList([for (final i in ids) ...i]);

  Set<String> _unpackIds(Uint8List packed) {
    final out = <String>{};
    for (var i = 0; i + kIdLength <= packed.length; i += kIdLength) {
      out.add(toHex(packed.sublist(i, i + kIdLength)));
    }
    return out;
  }

  /// Anti-entropy: tell a newly connected co-member which events we hold.
  Future<void> _syncRoomsWith(PeerIdentity peer) async {
    for (final log in _logs.values) {
      final s = log.state;
      if (!s.isMember(self.peerId) || !s.isMember(peer.peerId)) continue;
      final ordered = log.events.toList()..sort(RoomEvent.compare);
      final recent = ordered.length > _maxOfferIds
          ? ordered.sublist(ordered.length - _maxOfferIds)
          : ordered;
      _enqueue(
        dest: peer.peerId,
        roomId: log.roomId,
        content: MessageContent.control(
          MessageContent.kindSyncOffer,
          blobs: [_packIds(recent.map((e) => e.id))],
        ),
      );
    }
    unawaited(flushOutbox());
  }

  // ───────────────────────── control messages in ─────────────────────────

  Future<void> _onControl(OpenedMessage m) async {
    final roomId = m.roomId;
    if (roomId == null) return;
    switch (m.content.kind) {
      case MessageContent.kindRoomEvents:
        await _onRoomEvents(m, roomId);
      case MessageContent.kindSyncOffer:
        await _onSyncOffer(m, roomId);
      case MessageContent.kindSyncWant:
        await _onSyncWant(m, roomId);
      case MessageContent.kindJoinRequest:
        await _onJoinRequest(m, roomId);
    }
  }

  Future<void> _onRoomEvents(OpenedMessage m, Uint8List roomId) async {
    final roomHex = toHex(roomId);
    final existing = _logs[roomHex];
    final candidate = existing?.copy() ?? RoomLog(roomId);
    final prior = existing?.state.members.keys.toSet() ?? <String>{};

    final added = <RoomEvent>[];
    for (final blob in m.content.blobs) {
      try {
        final e = RoomEvent.decode(blob);
        if (await candidate.add(e)) added.add(e); // verifies the signature
      } on MeshException {
        continue; // bad event: skip it, keep the rest
      }
    }
    if (added.isEmpty) return;

    final st = candidate.state;
    final senderHex = m.sender.peerIdHex;
    final pending = _pendingJoins[roomHex] == senderHex;
    final bool accept;
    if (existing != null) {
      accept = prior.contains(senderHex) || st.members.containsKey(senderHex);
    } else {
      accept = st.exists &&
          st.isMember(m.sender.peerId) &&
          (st.isMember(self.peerId) || (pending && st.isPublic));
    }
    if (!accept) return;

    _logs[roomHex] = candidate;
    roomStore.saveEvents(added);
    roomStore.materialize(st, self.peerId, now());
    for (final mem in st.members.values) {
      directory.remember(mem.identity);
    }
    _nearbyRooms.remove(roomHex);

    if (!st.isMember(self.peerId) && pending && st.isPublic) {
      // Public room: we now hold its history; add ourselves.
      _pendingJoins.remove(roomHex);
      final before = [for (final x in st.members.values) x.identity];
      final ev = await RoomAuthor(identity, candidate).join();
      await _afterLocalChange(candidate, [ev], before);
    } else {
      if (st.isMember(self.peerId)) _pendingJoins.remove(roomHex);
      _emit(RoomsChanged(roomId));
    }
    // Reconcile with the sender: we may now know of events they lack, and
    // vice versa. Cheap thanks to the offer/want exchange.
    unawaited(_syncRoomsWith(m.sender));
  }

  Future<void> _onSyncOffer(OpenedMessage m, Uint8List roomId) async {
    final log = _logs[toHex(roomId)];
    if (log == null) return;
    final s = log.state;
    if (!s.isMember(self.peerId) || !s.isMember(m.sender.peerId)) return;
    if (m.content.blobs.isEmpty) return;
    final theirs = _unpackIds(m.content.blobs.first);

    final missing = log.missingFrom(theirs);
    if (missing.isNotEmpty) await _sendEvents(roomId, m.sender, missing);
    final wanted = log.wantedFrom(theirs);
    if (wanted.isNotEmpty) {
      _enqueue(
        dest: m.sender.peerId,
        roomId: roomId,
        content: MessageContent.control(
          MessageContent.kindSyncWant,
          blobs: [_packIds(wanted.take(_maxOfferIds).map(fromHex))],
        ),
      );
      unawaited(flushOutbox());
    }
  }

  Future<void> _onSyncWant(OpenedMessage m, Uint8List roomId) async {
    final log = _logs[toHex(roomId)];
    if (log == null) return;
    final s = log.state;
    if (!s.isMember(self.peerId) || !s.isMember(m.sender.peerId)) return;
    if (m.content.blobs.isEmpty) return;
    final wanted = _unpackIds(m.content.blobs.first);
    final events = [
      for (final e in log.events)
        if (wanted.contains(e.idHex)) e
    ];
    if (events.isNotEmpty) await _sendEvents(roomId, m.sender, events);
  }

  Future<void> _onJoinRequest(OpenedMessage m, Uint8List roomId) async {
    final log = _logs[toHex(roomId)];
    if (log == null) return;
    final state = log.state;
    if (!state.exists || state.deleted || !state.isMember(self.peerId)) return;
    if (state.isMember(m.sender.peerId)) {
      // Already a member (e.g. lost reply): resend the history.
      await _sendEvents(roomId, m.sender, log.events.toList());
      return;
    }

    if (m.content.blobs.isEmpty) {
      // Public join: hand over the history; the joiner adds themselves.
      if (state.isPublic) {
        directory.remember(m.sender);
        await _sendEvents(roomId, m.sender, log.events.toList());
      }
      return;
    }

    // Invite redemption.
    final Invite inv;
    try {
      inv = Invite.fromBytes(m.content.blobs.first);
      await inv.verify(nowMs: now());
    } on MeshException {
      return;
    }
    if (inv.kind != InviteKind.room ||
        inv.roomId == null ||
        toHex(inv.roomId!) != toHex(roomId) ||
        inv.inviter.peerIdHex != self.peerIdHex) {
      return; // not issued by us for this room
    }
    if (!state.can(self.peerId, Permission.manageMembers)) return;
    if (!_invites.consume(inv.nonce, now())) return; // single use
    peers.upsert(m.sender);
    await addMember(roomId, m.sender);
  }
}
