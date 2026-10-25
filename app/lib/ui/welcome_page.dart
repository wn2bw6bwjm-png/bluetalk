import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';

/// First launch: no registration, no login. A name is optional.
class WelcomePage extends ConsumerStatefulWidget {
  const WelcomePage({super.key});

  @override
  ConsumerState<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends ConsumerState<WelcomePage> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _go(String? name) =>
      ref.read(appControllerProvider.notifier).completeOnboarding(name);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text('BlueTalk',
                  style: Theme.of(context).textTheme.headlineLarge),
              const SizedBox(height: 12),
              const Text(
                'No account. No server. No cloud.\n\n'
                'A cryptographic identity was created on this device. '
                'Messages are end-to-end encrypted and travel directly '
                'between nearby phones, or hop through other phones that '
                'cannot read them.',
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _name,
                maxLength: 32,
                decoration: const InputDecoration(
                  labelText: 'Display name (optional)',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: _go,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                      onPressed: () => _go(null), child: const Text('Skip')),
                  const Spacer(),
                  FilledButton(
                      onPressed: () => _go(_name.text),
                      child: const Text('Continue')),
                ],
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
