/// Wire values of packet types. Values are part of the protocol: never
/// renumber, only append. 5..15 are reserved for room/group events.
enum PacketType {
  /// Signed identity announcement (public keys + display name).
  announce(1),

  /// End-to-end encrypted direct message.
  directMessage(2),

  /// Signed delivery acknowledgement (sent by the final recipient only).
  ack(3),

  /// Signed attestation by a relay that it verified and forwarded a packet.
  /// Hop-by-hop: addressed to the neighbour the packet came from, never
  /// forwarded itself.
  relayReceipt(4);

  const PacketType(this.wire);
  final int wire;

  static PacketType? fromWire(int v) {
    for (final t in PacketType.values) {
      if (t.wire == v) return t;
    }
    return null;
  }
}
