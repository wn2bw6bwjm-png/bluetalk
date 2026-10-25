import 'dart:typed_data';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late Actor alice;
  setUp(() async => alice = await makeActor());

  group('invites', () {
    test('contact invite round-trips through text and verifies', () async {
      final inv = await Invite.create(
          issuer: alice.identity, kind: InviteKind.contact, name: 'Alice');
      final text = inv.toText();
      expect(text, startsWith('mesh1:'));
      expect(text.length, lessThan(Invite.maxEncodedLength));
      final back = Invite.fromText(text);
      expect(await back.verify(), alice.pub);
      expect(back.name, 'Alice');
      expect(back.kind, InviteKind.contact);
    });

    test('room invite carries the room and survives surrounding whitespace',
        () async {
      final rid = randomBytes(16);
      final inv = await Invite.create(
        issuer: alice.identity,
        kind: InviteKind.room,
        name: 'Alice',
        roomId: rid,
        roomName: 'Hikers',
      );
      final back = Invite.fromText('  ${inv.toText()}\n');
      expect(back.roomId, rid);
      expect(back.roomName, 'Hikers');
      expect(await back.verify(), alice.pub);
    });

    test('tampering with any field breaks the signature', () async {
      final inv = await Invite.create(
        issuer: alice.identity,
        kind: InviteKind.room,
        name: 'Alice',
        roomId: randomBytes(16),
        roomName: 'Hikers',
      );
      Invite mod({String? name, Uint8List? room, int? exp, String? roomName}) =>
          Invite(
            kind: inv.kind,
            inviterKeys: inv.inviterKeys,
            name: name ?? inv.name,
            roomId: room ?? inv.roomId,
            roomName: roomName ?? inv.roomName,
            expiresAtMs: exp ?? inv.expiresAtMs,
            nonce: inv.nonce,
            signature: inv.signature,
          );
      for (final bad in [
        mod(name: 'Eve'),
        mod(room: randomBytes(16)),
        mod(exp: inv.expiresAtMs + 1),
        mod(roomName: 'Other'),
      ]) {
        await expectLater(bad.verify(), throwsA(isA<SignatureException>()));
      }
    });

    test('a different key cannot impersonate the issuer', () async {
      final mallory = await makeActor();
      final inv = await Invite.create(
          issuer: alice.identity, kind: InviteKind.contact, name: 'Alice');
      final swapped = Invite(
        kind: inv.kind,
        inviterKeys: Uint8List.fromList(
            [...mallory.pub.signPublicKey, ...mallory.pub.agreePublicKey]),
        name: inv.name,
        expiresAtMs: inv.expiresAtMs,
        nonce: inv.nonce,
        signature: inv.signature,
      );
      await expectLater(swapped.verify(), throwsA(isA<SignatureException>()));
    });

    test('expiry is enforced', () async {
      final inv = await Invite.create(
        issuer: alice.identity,
        kind: InviteKind.contact,
        name: 'A',
        validFor: const Duration(hours: 1),
        nowMs: 1000,
      );
      await expectLater(
          inv.verify(nowMs: 1000 + const Duration(hours: 2).inMilliseconds),
          throwsA(isA<ReplayException>()));
    });

    test('garbage input never crashes the parser', () {
      for (final s in [
        '',
        'hello',
        'mesh1:',
        'mesh1:!!!!',
        'mesh1:${'A' * 5000}',
        'mesh1:AAAA',
        'https://example.com/invite',
      ]) {
        expect(() => Invite.fromText(s), throwsA(isA<InvalidPacketException>()),
            reason: s.length > 20 ? s.substring(0, 20) : s);
      }
    });

    test('room invite without a room id is rejected at parse time', () async {
      final inv = await Invite.create(
          issuer: alice.identity, kind: InviteKind.contact, name: 'A');
      final bytes = Invite.fromBytes(inv.toBytes()); // sanity
      expect(bytes.kind, InviteKind.contact);
      expect(
        () => Invite.create(
            issuer: alice.identity, kind: InviteKind.room, name: 'A'),
        throwsArgumentError,
      );
    });

    test('control characters are stripped from names', () async {
      final inv = await Invite.create(
          issuer: alice.identity,
          kind: InviteKind.contact,
          name: 'Al\u0000ice\n');
      expect(inv.name, 'Alice');
    });
  });

  group('themes', () {
    test('all seven required presets exist', () {
      expect(themePresets.map((p) => p.id), [
        'midnight',
        'ocean',
        'forest',
        'purple',
        'sunset',
        'monochrome',
        'cyberpunk',
      ]);
    });

    test('every preset is readable (WCAG AA 4.5:1 for text pairs)', () {
      for (final p in themePresets) {
        final c = p.colors;
        expect(contrastRatio(c.onSurface, c.surface), greaterThanOrEqualTo(4.5),
            reason: '${p.id} onSurface/surface');
        expect(
            contrastRatio(c.onSurface, c.background), greaterThanOrEqualTo(4.5),
            reason: '${p.id} onSurface/background');
        expect(contrastRatio(c.onPrimary, c.primary), greaterThanOrEqualTo(4.5),
            reason: '${p.id} onPrimary/primary');
      }
    });

    test('contrast math: black/white is 21:1', () {
      expect(contrastRatio(0xFF000000, 0xFFFFFFFF), closeTo(21, 0.01));
      expect(contrastRatio(0xFF777777, 0xFF777777), closeTo(1, 0.001));
    });

    test('AMOLED forces a pure black background', () {
      final s = const AppThemeSettings(mode: ThemeModeSetting.amoled);
      expect(s.resolveColors()!.background, 0xFF000000);
      final fromDark = const AppThemeSettings(
              mode: ThemeModeSetting.amoled, presetId: 'cyberpunk')
          .resolveColors()!;
      expect(fromDark.background, 0xFF000000);
      expect(fromDark.primary, presetById('cyberpunk')!.colors.primary);
    });

    test('system/light/dark use the platform scheme unless a preset is set',
        () {
      expect(const AppThemeSettings().resolveColors(), isNull);
      expect(
          const AppThemeSettings(mode: ThemeModeSetting.dark, presetId: 'ocean')
              .resolveColors(),
          presetById('ocean')!.colors);
    });

    test('custom colours are used and survive JSON persistence', () {
      const custom = ThemeColors(
        primary: 0xFF123456,
        onPrimary: 0xFFFFFFFF,
        background: 0xFF101010,
        surface: 0xFF202020,
        onSurface: 0xFFEEEEEE,
        accent: 0xFFFF0000,
      );
      final s = const AppThemeSettings(mode: ThemeModeSetting.custom)
          .copyWith(custom: custom)
          .withRoomColor('abcd', 0x00FF8800);
      final back = AppThemeSettings.fromJsonString(s.toJsonString());
      expect(back.mode, ThemeModeSetting.custom);
      expect(back.resolveColors(), custom);
      expect(back.colorForRoom('abcd'), 0xFFFF8800); // alpha forced opaque
    });

    test('corrupt stored settings fall back to defaults, never throw', () {
      for (final s in [
        null,
        '',
        'not json',
        '[]',
        '{"mode": 5}',
        '{"custom": {"primary": "red"}}',
        '{"preset": "nope"}'
      ]) {
        final t = AppThemeSettings.fromJsonString(s);
        expect(t.mode, isA<ThemeModeSetting>());
        expect(t.custom, isNull);
        expect(t.presetId, isNull);
      }
    });

    test('room colour can be cleared', () {
      final s = const AppThemeSettings()
          .withRoomColor('r', 0xFF00FF00)
          .withRoomColor('r', null);
      expect(s.colorForRoom('r'), isNull);
    });
  });
}
