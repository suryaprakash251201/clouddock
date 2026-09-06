// Settings + about.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/account_store.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(accountStoreProvider).valueOrNull?.length ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('Connected accounts'),
            subtitle: Text('$count'),
          ),
          const Divider(height: 1),
          const ListTile(
            leading: Icon(Icons.security_outlined),
            title: Text('Secrets stay on-device'),
            subtitle: Text(
              'Access keys in Keychain/Keystore, metadata only in app prefs. Nothing leaves the phone except S3 API calls.',
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About CloudDock'),
            subtitle: const Text(
              'v0.1.0 • S3 browser for AWS S3, Cloudflare R2, MinIO, Wasabi, Backblaze B2 + any S3-compatible server.',
            ),
          ),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Tips:\n'
              '• R2 uses region "auto" and path-style.\n'
              '• MinIO dev servers can disable SSL.\n'
              '• If listing fails, toggle path-style in account settings.\n'
              '• Share creates a 1-hour presigned link.',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
