// Accounts list: entry point of the app.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/s3/s3_account.dart';
import '../../core/storage/account_store.dart';
import '../transfers/transfer_manager.dart';

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountStoreProvider);
    final transfers = ref.watch(transferManagerProvider);
    final activeCount = transfers
        .where(
          (t) =>
              t.status == TransferStatus.running ||
              t.status == TransferStatus.queued,
        )
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('CloudDock'),
        actions: [
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.sync),
                tooltip: 'Transfers',
                onPressed: () => context.push('/transfers'),
              ),
              if (activeCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: CircleAvatar(
                    radius: 9,
                    child: Text(
                      '$activeCount',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: accountsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load accounts: $e')),
        data: (accounts) {
          if (accounts.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_outlined, size: 64),
                    const SizedBox(height: 16),
                    const Text(
                      'No storage accounts yet',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Add AWS S3, Cloudflare R2, MinIO, Wasabi, Backblaze B2, or any S3-compatible server.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => context.push('/account'),
                      icon: const Icon(Icons.add),
                      label: const Text('Add account'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: accounts.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final a = accounts[i];
              return ListTile(
                leading: CircleAvatar(child: Text(a.provider.label[0])),
                title: Text(a.name),
                subtitle: Text('${a.provider.label} • ${a.endpoint}'),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'edit') {
                      context.push('/account?id=${a.id}');
                    } else if (v == 'delete') {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('Delete account?'),
                          content: Text(
                            'Remove "${a.name}"? Stored secrets are deleted from secure storage.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(c, true),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true && context.mounted) {
                        await ref
                            .read(accountStoreProvider.notifier)
                            .remove(a.id);
                      }
                    }
                  },
                  itemBuilder: (c) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
                onTap: () => context.push('/buckets/${a.id}'),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/account'),
        tooltip: 'Add account',
        child: const Icon(Icons.add),
      ),
    );
  }
}
