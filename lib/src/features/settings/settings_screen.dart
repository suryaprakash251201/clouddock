// Settings + about: glass info cards.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/account_store.dart';
import '../../ui/glass.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(accountStoreProvider).valueOrNull?.length ?? 0;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              const SectionLabel('General'),
              Glass(
                padding: const EdgeInsets.all(6),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.cloud_outlined),
                      title: const Text('Connected accounts'),
                      trailing: StatusPill(
                        label: '$count',
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.security_outlined),
                      title: const Text('Secrets stay on-device'),
                      subtitle: const Text(
                        'Access keys in Keychain/Keystore, metadata only in app prefs. Nothing leaves the phone except S3 API calls.',
                      ),
                    ),
                  ],
                ),
              ),
              const SectionLabel('About'),
              Glass(
                padding: const EdgeInsets.all(6),
                child: const ListTile(
                  leading: Icon(Icons.info_outline_rounded),
                  title: Text('CloudDock v1.0'),
                  subtitle: Text(
                    'S3 browser for AWS S3, Cloudflare R2, MinIO, Wasabi, Backblaze B2 + any S3-compatible server.',
                  ),
                ),
              ),
              const SectionLabel('Tips'),
              const Glass(
                padding: EdgeInsets.all(16),
                child: Text(
                  '• R2 uses region "auto" and path-style.\n'
                  '• MinIO dev servers can disable SSL.\n'
                  '• If listing fails, toggle path-style in account settings.\n'
                  '• Share creates a 1-hour presigned link.\n'
                  '• Tap any image, text, PDF, or video file to open it in-app.',
                  style: TextStyle(fontSize: 13, height: 1.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
