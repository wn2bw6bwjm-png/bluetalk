/// Protocol-wide constants. Changing any of these is a protocol change and
/// requires bumping [kProtocolVersion].
const int kProtocolVersion = 1;

/// Length in bytes of peer IDs and message IDs.
const int kIdLength = 16;

/// Hard upper bound for a serialized packet accepted by the decoder.
/// Larger input is rejected before parsing (DoS guard).
const int kMaxPacketBytes = 16 * 1024;

/// Maximum size of the (encrypted) payload field.
const int kMaxPayloadBytes = 12 * 1024;

/// Default and maximum TTL (hop budget) of a packet.
const int kDefaultTtl = 6;
const int kMaxTtl = 8;

/// Domain-separation labels. Every signature / KDF use has its own label so
/// that material produced for one purpose can never be replayed for another.
const String kSignDomainPacket = 'mesh/v1/packet-signature';
const String kKdfInfoDirect = 'mesh/v1/direct-message-key';
const String kPeerIdDomain = 'mesh/v1/peer-id';
