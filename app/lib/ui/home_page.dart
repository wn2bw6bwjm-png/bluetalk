import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chats_tab.dart';
import 'nearby_tab.dart';
import 'rooms_tab.dart';
import 'settings/settings_tab.dart';

/// Bottom navigation: Chats, Rooms, Nearby, Settings.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    const pages = [ChatsTab(), RoomsTab(), NearbyTab(), SettingsTab()];
    return Scaffold(
      body: SafeArea(child: pages[_index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline), label: 'Chats'),
          NavigationDestination(
              icon: Icon(Icons.groups_outlined), label: 'Rooms'),
          NavigationDestination(
              icon: Icon(Icons.bluetooth_searching), label: 'Nearby'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
      ),
    );
  }
}
