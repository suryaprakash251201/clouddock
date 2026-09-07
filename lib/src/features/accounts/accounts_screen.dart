// Accounts list: glass cards over a gradient backdrop.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/s3/s3_account.dart';
import '../../core/storage/account_store.dart';
import '../../ui/glass.dart';

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountStoreProvider);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          'CloudDock',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: accountsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Failed to load accounts: $e')),
            data: (accounts) {
              if (accounts.isEmpty) {
                return EmptyState(
                  icon: Icons.cloud_outlined,
                  title: 'No storage accounts yet',
                  subtitle: 'Add AWS S3, Cloudflare R2, MinIO, Wasabi, Backblaze B2, or any S3-compatible server.',
                  action: GlowButton(
                    label: 'Add account',
                    icon: Icons.add_rounded,
                    onPressed: () => context.push('/s3/account'),
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  const SectionLabel('Storage accounts'),
                  for (final a in accounts) ...[
                    _AccountCard(account: a),
                    const SizedBox(height: 12),
                  ],
                ],
              );
            },
          ),
        ),
      ),
      floatingActionButton: accountsAsync.valueOrNull?.isNotEmpty == true
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/s3/account'),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add'),
            )
          : null,
    );
  }
}

class _AccountCard extends ConsumerWidget {
  final S3Account account;
  const _AccountCard({required this.account});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Glass(
      padding: const EdgeInsets.all(16),
      onTap: () => context.push('/s3/buckets/${account.id}'),
      child: Row(
        children: [
          ProviderBadge(provider: account.provider),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${account.provider.label} • ${account.endpoint}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (v) async {
              if (v == 'edit') {
                context.push('/s3/account?id=${account.id}');
              } else if (v == 'delete') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Delete account?'),
                    content: Text(
                      'Remove "${account.name}"? Stored secrets are deleted from secure storage.',
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
                      .remove(account.id);
                }
              }
            },
            itemBuilder: (c) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}
