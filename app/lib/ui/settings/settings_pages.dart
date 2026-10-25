import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_engine/mesh_engine.dart';

import '../../application/app_controller.dart';
import '../widgets/common.dart';
import '../widgets/engine_access.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    final engine = engineOf(ref);
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(children: [
        ListTile(
          title: const Text('Display name'),
          subtitle: Text(app.name ?? '(not set)'),
          trailing: const Icon(Icons.edit),
          onTap: () async {
            final v = await promptText(context, 'Display name',
                initial: app.name ?? '', maxLength: 32);
            if (v != null && context.mounted) {
              await ref.read(appControllerProvider.notifier).updateName(v);
            }
          },
        ),
        ListTile(
          title: const Text('Status'),
          subtitle: Text(app.status ?? '(not set)'),
          trailing: const Icon(Icons.edit),
          onTap: () async {
            final v = await promptText(context, 'Status line',
                initial: app.status ?? '', maxLength: 64);
            if (v != null && context.mounted) {
              await ref.read(appControllerProvider.notifier).updateProfileText(status: v);
            }
          },
        ),
        ListTile(
          title: const Text('Bio'),
          subtitle: Text(app.bio ?? '(not set)'),
          trailing: const Icon(Icons.edit),
          onTap: () async {
            final v = await promptText(context, 'Bio',
                initial: app.bio ?? '', maxLength: 200, multiline: true);
            if (v != null && context.mounted) {
              await ref.read(appControllerProvider.notifier).updateProfileText(bio: v);
            }
          },
        ),
        ListTile(
          title: const Text('Peer ID'),
          subtitle: SelectableText(app.self?.peerIdHex ?? ''),
        ),
        ListTile(
          leading: const Icon(Icons.qr_code),
          title: const Text('Contact card'),
          subtitle: const Text('Let someone scan it to add you offline.'),
          onTap: engine == null
              ? null
              : () async {
                  final card = await guarded(context, engine.createContactInvite);
                  if (card != null && context.mounted) {
                    await showQrDialog(context, 'My contact card', card.toText());
                  }
                },
        ),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Avatars'),
          subtitle: Text('Letter avatars only. Custom avatar images are not implemented.'),
        ),
      ]),
    );
  }
}

class NotificationsPage extends ConsumerWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = engineOf(ref);
    final on = engine?.settings.getBool('notifications', fallback: true) ?? true;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(children: [
        SwitchListTile(
          title: const Text('Message notifications'),
          subtitle: const Text(
              'Shown on this device only. No push service is used, so they '
              'appear only while the app is allowed to run.'),
          value: on,
          onChanged: engine == null
              ? null
              : (v) {
                  engine.settings.setBool('notifications', v);
                  ref.read(revisionProvider.notifier).bump();
                },
        ),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Muted contacts, rooms and channels'),
          subtitle: Text('Mute them from their own screens.'),
        ),
      ]),
    );
  }
}

class PrivacyPage extends ConsumerWidget {
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = engineOf(ref);
    if (engine == null) return Scaffold(appBar: AppBar(), body: const SizedBox());
    final receipts = engine.settings.getBool('read_receipts', fallback: true);
    final blocked = engine.peers.blocked();
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: ListView(children: [
        SwitchListTile(
          title: const Text('Send read receipts'),
          subtitle: const Text('Direct chats only. Receipts are signed and verified.'),
          value: receipts,
          onChanged: (v) {
            engine.settings.setBool('read_receipts', v);
            ref.read(revisionProvider.notifier).bump();
          },
        ),
        const ListTile(
          title: Text('Telemetry, ads, analytics'),
          subtitle: Text('None. The app has no code for them and makes no internet requests.'),
        ),
        const Divider(),
        ListTile(title: Text('Blocked contacts (${blocked.length})')),
        for (final p in blocked)
          ListTile(
            leading: PeerAvatar(p.title),
            title: Text(p.title),
            subtitle: Text(p.identity.shortId),
            trailing: TextButton(
              onPressed: () => engine.blockPeer(p.identity.peerId, blocked: false),
              child: const Text('Unblock'),
            ),
          ),
        if (blocked.isEmpty)
          const ListTile(subtitle: Text('Messages from blocked contacts are dropped and never acknowledged.')),
      ]),
    );
  }
}

class SecurityPage extends ConsumerWidget {
  const SecurityPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    final engine = engineOf(ref);
    final verified = engine?.peers.all().where((p) => p.verified).toList() ?? const [];
    final unverified = engine?.peers.all().where((p) => !p.verified && !p.blocked).length ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: ListView(children: [
        ListTile(
          title: const Text('Your fingerprint'),
          subtitle: SelectableText(app.fingerprint,
              style: const TextStyle(fontFamily: 'monospace')),
          trailing: IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () => Clipboard.setData(ClipboardData(text: app.fingerprint)),
          ),
        ),
        const ListTile(
          title: Text('Encryption status'),
          subtitle: Text(
            'End-to-end: X25519 key agreement, HKDF-SHA256, ChaCha20-Poly1305. '
            'Every packet is signed with Ed25519. Relay phones cannot read '
            'messages. Private keys never leave this device\'s secure storage.\n\n'
            'Not provided: forward secrecy against later theft of a '
            'recipient\'s key, and hiding who talks to whom from relays.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.verified_user),
          title: Text('Verified contacts: ${verified.length}'),
          subtitle: Text('$unverified contact(s) not verified yet. Compare fingerprints '
              'in a chat\'s shield menu.'),
        ),
        for (final p in verified)
          ListTile(
            dense: true,
            leading: const Icon(Icons.check_circle_outline),
            title: Text(p.title),
            subtitle: Text(p.identity.shortId),
          ),
      ]),
    );
  }
}

class StoragePage extends ConsumerWidget {
  const StoragePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = engineOf(ref);
    if (engine == null) return Scaffold(appBar: AppBar(), body: const SizedBox());
    int count(String sql) => engine.database.db.select(sql).first.values.first as int;
    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: ListView(children: [
        const ListTile(
          title: Text('All data is stored on this device only'),
          subtitle: Text('SQLite database; private keys are in the OS secure storage.'),
        ),
        ListTile(title: const Text('Messages'), trailing: Text('${count('SELECT COUNT(*) FROM messages')}')),
        ListTile(title: const Text('Contacts'), trailing: Text('${count('SELECT COUNT(*) FROM peers')}')),
        ListTile(title: const Text('Rooms'), trailing: Text('${count('SELECT COUNT(*) FROM rooms')}')),
        ListTile(
          title: const Text('Waiting to send (outbox)'),
          trailing: Text('${engine.outbox.pendingCount()}'),
          subtitle: const Text('Kept across restarts; retried when peers appear.'),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.delete_sweep_outlined),
          title: const Text('Clear all messages'),
          subtitle: const Text('Keeps your identity, contacts and rooms.'),
          onTap: () async {
            if (await confirm(context, 'Clear all messages?', 'Messages on this device are deleted. Others keep their copies.',
                action: 'Clear', destructive: true)) {
              engine.database.transaction(() {
                engine.database.db.execute('DELETE FROM reactions');
                engine.database.db.execute('DELETE FROM messages');
                engine.database.db.execute('DELETE FROM outbox WHERE tracked = 1');
              });
              ref.read(revisionProvider.notifier).bump();
            }
          },
        ),
        ListTile(
          leading: Icon(Icons.delete_forever, color: Theme.of(context).colorScheme.error),
          title: const Text('Erase everything'),
          subtitle: const Text('Deletes keys, messages, rooms. You get a new identity.'),
          onTap: () async {
            if (await confirm(context, 'Erase everything?',
                'This cannot be undone. Contacts will see you as a new device.',
                action: 'Erase', destructive: true)) {
              await ref.read(appControllerProvider.notifier).wipeEverything();
            }
          },
        ),
      ]),
    );
  }
}

class NetworkPage extends ConsumerStatefulWidget {
  const NetworkPage({super.key});

  @override
  ConsumerState<NetworkPage> createState() => _NetworkPageState();
}

class _NetworkPageState extends ConsumerState<NetworkPage> {
  bool? _batteryOk;

  @override
  void initState() {
    super.initState();
    ref
        .read(appControllerProvider.notifier)
        .keepAlive
        .isIgnoringBatteryOptimizations()
        .then((v) {
      if (mounted) setState(() => _batteryOk = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final ctl = ref.read(appControllerProvider.notifier);
    final engine = engineOf(ref);
    final ios = Theme.of(context).platform == TargetPlatform.iOS;
    final bg = ctl.settings.getBool(AppController.backgroundServiceKey, fallback: true);
    final logLines = ref.watch(radioLogProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Network')),
      body: ListView(children: [
        ListTile(
          leading: Icon(app.networkRunning ? Icons.radar : Icons.portable_wifi_off),
          title: Text(app.networkRunning ? 'Radio on' : 'Radio off'),
          subtitle: Text(ios
              ? 'Multipeer (iPhone ↔ iPhone) and Bluetooth LE (iPhone ↔ Android)'
              : 'Bluetooth Low Energy (Android ↔ Android and Android ↔ iPhone)'),
        ),
        if (engine != null)
          ListTile(title: const Text('Direct links'), trailing: Text('${engine.linkCount}')),
        if (app.networkError != null)
          ListTile(leading: const Icon(Icons.error_outline), title: Text(app.networkError!)),
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: const Text('Restart radio'),
          onTap: () => ctl.restartNetwork(),
        ),
        const Divider(),
        if (ctl.keepAlive.supported) ...[
          SwitchListTile(
            title: const Text('Keep running in the background'),
            subtitle: const Text(
                'Shows a permanent notification and raises the app\'s '
                'priority so Android is less likely to stop the radio. '
                'It does not guarantee delivery.'),
            value: bg,
            onChanged: (v) async {
              await ctl.setBackgroundService(v);
              if (mounted) setState(() {});
            },
          ),
          ListTile(
            leading: Icon(_batteryOk == true ? Icons.battery_full : Icons.battery_alert),
            title: Text(_batteryOk == true
                ? 'Battery optimisation: not restricted'
                : 'Allow unrestricted battery use'),
            subtitle: const Text(
                'Many phones (Xiaomi, Huawei, Samsung…) also have their own '
                '"auto-start" and "battery saver" lists: add this app there.'),
            onTap: () async {
              await ctl.keepAlive.requestIgnoreBatteryOptimizations();
              final v = await ctl.keepAlive.isIgnoringBatteryOptimizations();
              if (mounted) setState(() => _batteryOk = v);
            },
          ),
        ],
        ExpansionTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: Text('Radio log (${logLines.length})'),
          subtitle: const Text('What the radio sees. Send this when devices do not find each other.'),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: logLines.join('\n')));
                    if (context.mounted) toast(context, 'Log copied');
                  },
                ),
                TextButton(
                  onPressed: () => ref.read(radioLogProvider.notifier).clear(),
                  child: const Text('Clear'),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SelectableText(
                logLines.isEmpty ? '(empty)' : logLines.reversed.take(80).toList().reversed.join('\n'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ],
        ),
        ListTile(
          leading: const Icon(Icons.warning_amber),
          title: const Text('Limits you should know'),
          subtitle: Text(ios
              ? 'iOS suspends apps in the background and never restarts one '
                  'you force-quit. Bluetooth background mode may wake the app '
                  'to talk to an Android phone, but nothing is guaranteed. '
                  'Two iPhones can only talk while both apps are open.'
              : 'Bluetooth range is roughly 10-30 m. Background operation '
                  'depends on your phone maker\'s battery rules and stops if '
                  'you swipe the app away. An iPhone must have the app open '
                  '(or be woken by iOS) to connect to you.'),
        ),
      ]),
    );
  }
}
