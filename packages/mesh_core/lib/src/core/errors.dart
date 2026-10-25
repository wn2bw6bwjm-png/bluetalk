/// Base class for every error the core raises on untrusted input. Callers can
/// catch [MeshException] to treat all of them as "drop this packet".
abstract class MeshException implements Exception {
  const MeshException(this.message);
  final String message;
  @override
  String toString() => '$runtimeType: $message';
}

/// Malformed bytes / out-of-range field / wrong version.
class InvalidPacketException extends MeshException {
  const InvalidPacketException(super.message);
}

/// Ed25519 signature did not verify, or sender ID is not bound to the key.
class SignatureException extends MeshException {
  const SignatureException(super.message);
}

/// Packet (by message ID) was already seen, or timestamp is outside the
/// accepted window.
class ReplayException extends MeshException {
  const ReplayException(super.message);
}

/// We do not (yet) know the sender's public keys.
class UnknownSenderException extends MeshException {
  const UnknownSenderException(super.message);
}

/// The packet is addressed to a different peer.
class NotForUsException extends MeshException {
  const NotForUsException(super.message);
}

/// AEAD authentication failed or the plaintext is malformed.
class DecryptionException extends MeshException {
  const DecryptionException(super.message);
}

/// Hop budget exhausted: the packet must not be forwarded any further.
class TtlExpiredException extends MeshException {
  const TtlExpiredException(super.message);
}

/// A neighbour exceeded the forwarding rate limit; the packet is dropped.
class RateLimitedException extends MeshException {
  const RateLimitedException(super.message);
}

/// No link can carry the packet.
class NoRouteException extends MeshException {
  const NoRouteException(super.message);
}

/// The sender is blocked by the local user; the packet is dropped silently
/// (no delivery, no acknowledgement).
class BlockedException extends MeshException {
  const BlockedException(super.message);
}
