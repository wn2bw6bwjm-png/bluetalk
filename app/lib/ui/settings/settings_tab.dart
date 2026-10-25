import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/app_controller.dart';
import 'appearance_page.dart';
import 'settings_pages.dart';

class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    Widget tile(IconData icon, String title, String subtitle, Widget page) =>
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => page)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        ListTile(
          leading: CircleAvatar(child: Text((app.name ?? '?').characters.first.toUpperCase())),
          title: Text(app.name ?? '(no name)'),
          subtitle: Text(app.self?.shortId ?? ''),
        ),
        const Divider(),
        tile(Icons.person_outline, 'Profile', 'Name, peer ID, contact card', const ProfilePage()),
        tile(Icons.palette_outlined, 'Appearance', 'Theme, colours', const AppearancePage()),
        tile(Icons.notifications_outlined, 'Notifications', 'Local only', const NotificationsPage()),
        tile(Icons.visibility_outlined, 'Privacy', 'Read receipts, blocked contacts', const PrivacyPage()),
        tile(Icons.lock_outline, 'Security', 'Fingerprint, encryption status', const SecurityPage()),
        tile(Icons.storage_outlined, 'Storage', 'Local data, queue, erase', const StoragePage()),
        tile(Icons.wifi_tethering, 'Network', 'Radio status and limits', const NetworkPage()),
        const AboutTile(),
      ]),
    );
  }
}

class AboutTile extends StatelessWidget {
  const AboutTile({super.key});
  @override
  Widget build(BuildContext context) => const ListTile(
        leading: Icon(Icons.info_outline),
        title: Text('No account · no server · no cloud'),
        subtitle: Text(
            'No telemetry, ads or analytics. This app makes no internet requests.'),
      );
}
