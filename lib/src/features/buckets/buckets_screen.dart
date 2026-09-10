// Bucket list for one account: glass cards.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/prefs/app_prefs.dart';
import '../../core/s3/s3_account.dart';
import '../../core/s3/s3_client.dart';
import '../../core/s3/s3_models.dart';
import '../../core/storage/account_store.dart';
import '../../ui/floating_nav_bar.dart';
import '../../ui/glass.dart';

class BucketsScreen extends ConsumerStatefulWidget {
  final String accountId;
  const BucketsScreen({super.key, required this.accountId});

  @override
  ConsumerState<BucketsScreen> createState() => _BucketsState();
}

class _BucketsState extends ConsumerState<BucketsScreen> {
  late Future<List<S3Bucket>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<S3Bucket>> _load() {
    final account = ref.read(accountByIdProvider(widget.accountId));
    if (account == null) throw StateError('Account not found');
    final client = S3Client(account);
    return client.listBuckets().whenComplete(client.close);
  }

  void _refresh() => setState(() => _future = _load());

  Future<void> _createBucket() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('New bucket'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'my-bucket'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      final account = ref.read(accountByIdProvider(widget.accountId))!;
      final client = S3Client(account);
      try {
        await client.createBucket(name);
      } finally {
        client.close();
      }
      _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Bucket "$name" created')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Create failed: $e')));
      }
    }
  }

  Future<void> _deleteBucket(String bucket) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete "$bucket"?'),
        content: const Text('The bucket must be empty. This cannot be undone.'),
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
    if (ok != true) return;
    try {
      final account = ref.read(accountByIdProvider(widget.accountId))!;
      final client = S3Client(account);
      try {
        await client.deleteBucket(bucket);
      } finally {
        client.close();
      }
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountByIdProvider(widget.accountId));
    final viewMode = ref.watch(viewModeProvider);
    if (account == null) {
      return const Scaffold(body: Center(child: Text('Account not found')));
    }
    final isGrid = viewMode == ViewMode.grid;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          account.name,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            icon: Icon(
              isGrid ? Icons.view_list_rounded : Icons.grid_view_rounded,
            ),
            tooltip: isGrid ? 'List view' : 'Grid view',
            onPressed: () => ref.read(viewModeProvider.notifier).toggle(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AppBackground(
        child: SafeArea(
          child: FutureBuilder<List<S3Bucket>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not list buckets',
                  subtitle: '${snap.error}',
                  action: GlowButton(
                    label: 'Retry',
                    icon: Icons.refresh_rounded,
                    onPressed: _refresh,
                  ),
                );
              }
              final buckets = snap.data ?? [];
              if (buckets.isEmpty) {
                return EmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: 'No buckets',
                  subtitle: 'Create your first bucket to get started.',
                  action: GlowButton(
                    label: 'New bucket',
                    icon: Icons.add_rounded,
                    onPressed: _createBucket,
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  kFloatingNavBarClearance,
                ),
                children: [
                  _AccountStrip(account: account),
                  const SectionLabel('Buckets'),
                  if (isGrid)
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.92,
                          ),
                      itemCount: buckets.length,
                      itemBuilder: (c, i) => _BucketGridTile(
                        bucket: buckets[i],
                        account: account,
                        onTap: () => context.push(
                          '/s3/browse/${widget.accountId}/${buckets[i].name}',
                        ),
                        onDelete: () => _deleteBucket(buckets[i].name),
                      ),
                    )
                  else
                    for (final b in buckets) ...[
                      Glass(
                        padding: const EdgeInsets.all(14),
                        onTap: () => context.push(
                          '/s3/browse/${widget.accountId}/${b.name}',
                        ),
                        child: Row(
                          children: [
                            ProviderBadge(provider: account.provider, size: 44),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    b.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15.5,
                                    ),
                                  ),
                                  if (b.creationDate != null)
                                    Text(
                                      'Created ${b.creationDate!.toLocal()}'
                                          .split('.')
                                          .first,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.55),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline_rounded),
                              tooltip: 'Delete bucket',
                              onPressed: () => _deleteBucket(b.name),
                            ),
                            const Icon(Icons.chevron_right_rounded),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                ],
              );
            },
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createBucket,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Bucket'),
      ),
    );
  }
}

class _AccountStrip extends StatelessWidget {
  final S3Account account;
  const _AccountStrip({required this.account});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Glass(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      radius: 16,
      child: Row(
        children: [
          Icon(Icons.cloud_done_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${account.provider.label} • ${account.endpoint}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Grid tile for buckets (default view).
class _BucketGridTile extends StatelessWidget {
  final S3Bucket bucket;
  final S3Account account;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _BucketGridTile({
    required this.bucket,
    required this.account,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Glass(
      padding: const EdgeInsets.all(14),
      radius: 18,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProviderBadge(provider: account.provider, size: 44),
              const Spacer(),
              InkWell(
                onTap: onDelete,
                borderRadius: BorderRadius.circular(99),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline_rounded, size: 20),
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            bucket.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            bucket.creationDate == null
                ? account.provider.label
                : 'Created ${bucket.creationDate!.toLocal()}'.split('.').first,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: scheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}
