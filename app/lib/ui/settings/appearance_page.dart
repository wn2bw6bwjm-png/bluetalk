import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_core/mesh_core.dart';

import '../../application/app_controller.dart';
import '../widgets/common.dart';

/// System / Light / Dark / AMOLED / Custom, seven presets and editable colours.
/// Changes apply immediately (the MaterialApp watches the settings) and are
/// saved locally.
class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(appControllerProvider.select((s) => s.theme));
    final ctl = ref.read(appControllerProvider.notifier);
    final resolved = theme.resolveColors();

    void setMode(ThemeModeSetting m) {
      var next = theme.copyWith(mode: m);
      if (m == ThemeModeSetting.custom && theme.custom == null) {
        // Start editing from the current palette (or Midnight).
        next = next.copyWith(custom: resolved ?? presetById('midnight')!.colors);
      }
      ctl.setTheme(next);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('Mode'),
        ),
        for (final m in ThemeModeSetting.values)
          ListTile(
            leading: Icon(theme.mode == m ? Icons.radio_button_checked : Icons.radio_button_unchecked),
            title: Text(switch (m) {
              ThemeModeSetting.system => 'System',
              ThemeModeSetting.light => 'Light',
              ThemeModeSetting.dark => 'Dark',
              ThemeModeSetting.amoled => 'AMOLED (pure black)',
              ThemeModeSetting.custom => 'Custom',
            }),
            onTap: () => setMode(m),
          ),
        const Divider(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text('Presets'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in themePresets)
              ChoiceChip(
                avatar: CircleAvatar(backgroundColor: Color(p.colors.primary)),
                label: Text(p.name),
                selected: theme.presetId == p.id,
                onSelected: (sel) {
                  if (!sel) {
                    ctl.setTheme(theme.copyWith(clearPreset: true));
                    return;
                  }
                  // A preset on System would be ignored; use a mode that applies it.
                  final mode = theme.mode == ThemeModeSetting.system
                      ? (p.colors.isDark ? ThemeModeSetting.dark : ThemeModeSetting.light)
                      : theme.mode;
                  ctl.setTheme(theme.copyWith(presetId: p.id, mode: mode, custom: p.colors));
                },
              ),
          ]),
        ),
        if (theme.mode == ThemeModeSetting.custom && theme.custom != null) ...[
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('Custom colours'),
          ),
          _ColorTile('Primary', theme.custom!.primary,
              (c) => ctl.setTheme(theme.copyWith(custom: theme.custom!.copyWith(primary: c)))),
          _ColorTile('On primary', theme.custom!.onPrimary,
              (c) => ctl.setTheme(theme.copyWith(custom: theme.custom!.copyWith(onPrimary: c)))),
          _ColorTile('Background', theme.custom!.background,
              (c) => ctl.setTheme(theme.copyWith(custom: theme.custom!.copyWith(background: c)))),
          _ColorTile('Surface', theme.custom!.surface,
              (c) => ctl.setTheme(theme.copyWith(custom: theme.custom!.copyWith(surface: c)))),
          _ColorTile('Text', theme.custom!.onSurface,
              (c) => ctl.setTheme(theme.copyWith(custom: theme.custom!.copyWith(onSurface: c)))),
          _ColorTile('Accent', theme.custom!.accent,
              (c) => ctl.setTheme(theme.copyWith(custom: theme.custom!.copyWith(accent: c)))),
          if (contrastRatio(theme.custom!.onSurface, theme.custom!.surface) < 4.5 ||
              contrastRatio(theme.custom!.onSurface, theme.custom!.background) < 4.5)
            const ListTile(
              leading: Icon(Icons.warning_amber),
              title: Text('Low contrast: text may be hard to read.'),
            ),
        ],
        const Divider(),
        const ListTile(
          leading: Icon(Icons.groups),
          title: Text('Room colours'),
          subtitle: Text(
              'Open a room → Room settings to change its colour for everyone '
              '(if you manage it) or only on this device.'),
        ),
      ]),
    );
  }
}

class _ColorTile extends StatelessWidget {
  const _ColorTile(this.label, this.value, this.onChanged);
  final String label;
  final int value;
  final void Function(int) onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(label),
        subtitle: Text('#${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}'),
        trailing: CircleAvatar(backgroundColor: Color(value), radius: 14),
        onTap: () async {
          final picked = await _pickColorOrHex(context, value);
          if (picked != null) onChanged(picked);
        },
      );

  static Future<int?> _pickColorOrHex(BuildContext context, int current) {
    final hex = TextEditingController(
        text: (current & 0xFFFFFF).toRadixString(16).padLeft(6, '0'));
    return showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Colour'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in kSwatches)
                GestureDetector(
                  onTap: () => Navigator.pop(c, s),
                  child: CircleAvatar(backgroundColor: Color(s), radius: 16),
                ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: hex,
              maxLength: 6,
              decoration: const InputDecoration(prefixText: '#', labelText: 'Hex RRGGBB'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(hex.text, radix: 16);
              if (v != null) Navigator.pop(c, 0xFF000000 | v);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}
