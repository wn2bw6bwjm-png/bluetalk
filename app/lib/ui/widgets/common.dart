import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_engine/mesh_engine.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Colour swatches offered in pickers (also usable as room colours).
const List<int> kSwatches = [
  0xFFE53935, 0xFFD81B60, 0xFF8E24AA, 0xFF5E35B1,
  0xFF3949AB, 0xFF1E88E5, 0xFF00ACC1, 0xFF00897B,
  0xFF43A047, 0xFF7CB342, 0xFFFDD835, 0xFFFB8C00,
  0xFFF4511E, 0xFF6D4C41, 0xFF546E7A, 0xFF212121,
];

Future<bool> confirm(
  BuildContext context,
  String title,
  String message, {
  String action = 'OK',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(c).colorScheme.error)
              : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

Future<String?> promptText(
  BuildContext context,
  String title, {
  String initial = '',
  String? hint,
  int maxLength = 64,
  bool multiline = false,
}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLength: maxLength,
        minLines: 1,
        maxLines: multiline ? 5 : 1,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('OK')),
      ],
    ),
  );
}

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Runs [action]; shows MeshException / argument errors as a snack bar.
Future<T?> guarded<T>(BuildContext context, Future<T> Function() action) async {
  try {
    return await action();
  } on MeshException catch (e) {
    if (context.mounted) toast(context, e.message);
  } on ArgumentError catch (e) {
    if (context.mounted) toast(context, '${e.message}');
  } catch (e) {
    if (context.mounted) toast(context, 'Error: $e');
  }
  return null;
}

/// Shows text as a QR code (invites, contact cards), with copy.
Future<void> showQrDialog(BuildContext context, String title, String data) {
  return showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // QR needs a light background to be scannable in dark themes.
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(
                data: data,
                size: 240,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Works without internet. Let the other person scan this, '
              'or copy the text and send it any way you like.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: data));
            if (c.mounted) toast(c, 'Copied');
          },
          child: const Text('Copy text'),
        ),
        TextButton(
            onPressed: () => Navigator.pop(c), child: const Text('Close')),
      ],
    ),
  );
}

/// Full-screen QR scanner. Returns the first scanned text or null.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan invite')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          for (final b in capture.barcodes) {
            final v = b.rawValue;
            if (v != null && v.startsWith(Invite.scheme)) {
              _done = true;
              Navigator.pop(context, v);
              return;
            }
          }
        },
      ),
    );
  }
}

/// Asks for an invite by scanning or pasting; returns the text or null.
Future<String?> askForInvite(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.qr_code_scanner),
            title: const Text('Scan QR code'),
            onTap: () => Navigator.pop(c, 'scan'),
          ),
          ListTile(
            leading: const Icon(Icons.paste),
            title: const Text('Paste invite text'),
            onTap: () => Navigator.pop(c, 'paste'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return null;
  if (choice == 'scan') {
    return Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
  }
  final text = await promptText(context, 'Paste invite',
      hint: 'mesh1:…', maxLength: Invite.maxEncodedLength);
  return text?.trim();
}

Future<void> showFingerprintDialog(
  BuildContext context, {
  required PeerIdentity identity,
  required bool verified,
  required void Function(bool) onVerified,
}) async {
  final fp = await identity.fingerprint();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Verify identity'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Compare this fingerprint with the one shown on the other '
              "person's device (Settings → Security), in person or over a "
              'channel you trust. If they match, nobody is impersonating '
              'them.',
            ),
            const SizedBox(height: 12),
            SelectableText(fp,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 15)),
            const SizedBox(height: 8),
            Text('Peer ID: ${identity.peerIdHex}',
                style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
      actions: [
        if (verified)
          TextButton(
              onPressed: () {
                onVerified(false);
                Navigator.pop(c);
              },
              child: const Text('Remove verification')),
        FilledButton(
          onPressed: () {
            onVerified(true);
            Navigator.pop(c);
          },
          child: Text(verified ? 'Still matches' : 'They match'),
        ),
      ],
    ),
  );
}

Future<int?> pickColor(BuildContext context, {int? current}) {
  return showDialog<int>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Colour'),
      content: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final s in kSwatches)
            GestureDetector(
              onTap: () => Navigator.pop(c, s),
              child: CircleAvatar(
                backgroundColor: Color(s),
                radius: 18,
                child: current == s
                    ? const Icon(Icons.check, color: Colors.white, size: 18)
                    : null,
              ),
            ),
        ],
      ),
    ),
  );
}

class StatusTick extends StatelessWidget {
  const StatusTick(this.status, {super.key});
  final MsgStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (status) {
      MsgStatus.queued => (Icons.schedule, 'queued'),
      MsgStatus.sent => (Icons.check, 'sent'),
      MsgStatus.relayed => (Icons.alt_route, 'relayed'),
      MsgStatus.delivered => (Icons.done_all, 'delivered'),
      MsgStatus.read => (Icons.done_all, 'read'),
      MsgStatus.failed => (Icons.error_outline, 'failed'),
    };
    final color = status == MsgStatus.read
        ? Theme.of(context).colorScheme.primary
        : status == MsgStatus.failed
            ? Theme.of(context).colorScheme.error
            : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 2),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class PeerAvatar extends StatelessWidget {
  const PeerAvatar(this.title, {super.key, this.color, this.radius = 20});
  final String title;
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final letter = title.isEmpty ? '?' : String.fromCharCode(title.runes.first);
    return CircleAvatar(
      radius: radius,
      backgroundColor: color ?? Theme.of(context).colorScheme.primaryContainer,
      child: Text(letter.toUpperCase()),
    );
  }
}
