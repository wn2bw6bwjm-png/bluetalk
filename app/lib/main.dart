import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_core/mesh_core.dart';

import 'application/app_controller.dart';
import 'ui/home_page.dart';
import 'ui/theme_builder.dart';
import 'ui/welcome_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: MeshApp()));
}

class MeshApp extends ConsumerWidget {
  const MeshApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(appControllerProvider.select((s) => s.phase));
    final theme = ref.watch(appControllerProvider.select((s) => s.theme));
    return MaterialApp(
      title: 'BlueTalk',
      debugShowCheckedModeBanner: false,
      themeMode: themeModeFor(theme),
      theme: buildTheme(theme, Brightness.light),
      darkTheme: buildTheme(theme, Brightness.dark),
      home: switch (phase) {
        Phase.loading => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
        Phase.welcome => const WelcomePage(),
        Phase.ready => const HomePage(),
        Phase.failed => const _FailedPage(),
      },
    );
  }
}

class _FailedPage extends ConsumerWidget {
  const _FailedPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final err = ref.watch(appControllerProvider.select((s) => s.error));
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not open local storage.\n\n$err'),
        ),
      ),
    );
  }
}

// Re-exported so widgets can pick a theme mode without importing core.
ThemeMode themeModeFor(AppThemeSettings s) {
  switch (s.mode) {
    case ThemeModeSetting.system:
      return ThemeMode.system;
    case ThemeModeSetting.light:
      return ThemeMode.light;
    case ThemeModeSetting.dark:
    case ThemeModeSetting.amoled:
      return ThemeMode.dark;
    case ThemeModeSetting.custom:
      final c = s.resolveColors();
      return c == null
          ? ThemeMode.system
          : (c.isDark ? ThemeMode.dark : ThemeMode.light);
  }
}
