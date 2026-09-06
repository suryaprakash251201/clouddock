// Bucket list for one account.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/s3/s3_account.dart';
import '../../core/s3/s3_client.dart';
import '../../core/s3/s3_models.dart';
import '../../core/storage/account_store.dart';

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
          decoration: const InputDecoration(
            hintText: 'my-bucket',
            border: OutlineInputBorder(),
          ),
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
    if (account == null) {
      return const Scaffold(body: Center(child: Text('Account not found')));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('${account.name} • ${account.provider.label}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<S3Bucket>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 12),
                    Text('${snap.error}', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _refresh,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          final buckets = snap.data ?? [];
          if (buckets.isEmpty) {
            return const Center(child: Text('No buckets. Create one below.'));
          }
          return ListView.separated(
            itemCount: buckets.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final b = buckets[i];
              return ListTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: Text(b.name),
                subtitle: b.creationDate == null
                    ? null
                    : Text('Created ${b.creationDate!.toLocal()}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete bucket',
                  onPressed: () => _deleteBucket(b.name),
                ),
                onTap: () =>
                    context.push('/browse/${widget.accountId}/${b.name}'),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createBucket,
        icon: const Icon(Icons.add),
        label: const Text('Bucket'),
      ),
    );
  }
}
