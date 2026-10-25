import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

import 'support/memory_secret_store.dart';

void main() {
  group('IdentityService', () {
    test('first launch creates an identity and persists only in the store',
        () async {
      final store = MemorySecretStore();
      final svc = IdentityService(store);
      final id = await svc.loadOrCreate();
      expect(id.peerId.length, 16);
      expect(store.data.containsKey(IdentityService.storageKey), isTrue);
      expect(store.data[IdentityService.storageKey]!.length, 64);
    });

    test('peer ID is stable across restarts', () async {
      final store = MemorySecretStore();
      final first = await IdentityService(store).loadOrCreate();
      final second = await IdentityService(store).loadOrCreate(); // new process
      expect(second.public.peerIdHex, first.public.peerIdHex);
      expect(second.public.signPublicKey, first.public.signPublicKey);
      expect(second.public.agreePublicKey, first.public.agreePublicKey);
    });

    test('different devices get different identities', () async {
      final a = await IdentityService(MemorySecretStore()).loadOrCreate();
      final b = await IdentityService(MemorySecretStore()).loadOrCreate();
      expect(a.public.peerIdHex, isNot(b.public.peerIdHex));
    });

    test('wipe destroys the identity; next launch creates a new one', () async {
      final store = MemorySecretStore();
      final svc = IdentityService(store);
      final old = await svc.loadOrCreate();
      await svc.wipe();
      expect(store.data, isEmpty);
      final fresh = await svc.loadOrCreate();
      expect(fresh.public.peerIdHex, isNot(old.public.peerIdHex));
    });

    test('corrupt stored secret is not trusted; fresh identity is created',
        () async {
      final store = MemorySecretStore();
      store.data[IdentityService.storageKey] = Uint8List(10);
      final id = await IdentityService(store).loadOrCreate();
      expect(id.peerId.length, 16);
      expect(store.data[IdentityService.storageKey]!.length, 64);
    });
  });

  group('PeerIdentity', () {
    test('peer ID is derived from BOTH public keys', () async {
      final a = await IdentityService(MemorySecretStore()).loadOrCreate();
      final b = await IdentityService(MemorySecretStore()).loadOrCreate();
      final mixed = await PeerIdentity.fromPublicKeys(
        signPublicKey: a.public.signPublicKey,
        agreePublicKey: b.public.agreePublicKey,
      );
      expect(mixed.peerIdHex, isNot(a.public.peerIdHex));
      expect(mixed.peerIdHex, isNot(b.public.peerIdHex));
    });

    test('fingerprint is 16 groups of 4 hex chars and deterministic', () async {
      final a = await IdentityService(MemorySecretStore()).loadOrCreate();
      final fp = await a.public.fingerprint();
      expect(fp, matches(RegExp(r'^([0-9A-F]{4} ){15}[0-9A-F]{4}$')));
      expect(await a.public.fingerprint(), fp);
    });

    test('rejects public keys of the wrong length', () {
      expect(
        PeerIdentity.fromPublicKeys(
          signPublicKey: Uint8List(31),
          agreePublicKey: Uint8List(32),
        ),
        throwsA(isA<InvalidPacketException>()),
      );
    });
  });

  group('known-answer tests (library wiring)', () {
    test('Ed25519 public key + signature match RFC 8032 test vector 1',
        () async {
      final id = await LocalIdentity.fromSeeds(
        fromHex(
            '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'),
        Uint8List(32)..[0] = 1,
      );
      expect(
        toHex(id.public.signPublicKey),
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
      );
      final sig = await id.sign(Uint8List(0));
      expect(
        toHex(sig),
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e0652249015'
        '55fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );
      expect(await id.public.verify(Uint8List(0), sig), isTrue);
    });

    test('X25519 agreement matches RFC 7748 §6.1', () async {
      final alice = await LocalIdentity.fromSeeds(
        Uint8List(32)..[0] = 9,
        fromHex(
            '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a'),
      );
      expect(
        toHex(alice.public.agreePublicKey),
        '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a',
      );
      final shared = await alice.agree(fromHex(
          'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f'));
      expect(
        toHex(shared),
        '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742',
      );
    });
  });
}
