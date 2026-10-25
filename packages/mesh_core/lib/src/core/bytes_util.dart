import 'dart:math';
import 'dart:typed_data';

/// Cryptographically secure random bytes (backed by the OS CSPRNG).
final Random _secureRandom = Random.secure();

Uint8List randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _secureRandom.nextInt(256);
  }
  return out;
}

String toHex(List<int> bytes) {
  final b = StringBuffer();
  for (final v in bytes) {
    b.write(v.toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

Uint8List fromHex(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  if (clean.length.isOdd) {
    throw const FormatException('Odd-length hex string');
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Constant-time equality for secrets / MACs / IDs.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List concatBytes(Iterable<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}

/// Big-endian fixed-width integer encoders used by the canonical signing
/// layout and the fragment header.
Uint8List u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v);
Uint8List u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);
Uint8List u64(int v) => Uint8List(8)..buffer.asByteData().setUint64(0, v);
