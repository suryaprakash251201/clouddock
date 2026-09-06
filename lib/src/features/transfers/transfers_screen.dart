// Transfer queue screen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import 'transfer_manager.dart';

class TransfersScreen extends ConsumerWidget {
  const TransfersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(transferManagerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfers'),
        actions: [
          if (tasks.any(
            (t) =>
                t.status == TransferStatus.done ||
                t.status == TransferStatus.canceled,
          ))
            TextButton(
              onPressed: () =>
                  ref.read(transferManagerProvider.notifier).clearFinished(),
              child: const Text('Clear finished'),
            ),
        ],
      ),
      body: tasks.isEmpty
          ? const Center(child: Text('No transfers yet.'))
          : ListView.separated(
              itemCount: tasks.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final t = tasks[i];
                return ListTile(
                  leading: Icon(
                    t.type == TransferType.upload
                        ? Icons.upload
                        : Icons.download,
                  ),
                  title: Text(
                    t.key.split('/').last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${t.bucket} • ${(t.progress * 100).toStringAsFixed(0)}%',
                      ),
                      if (t.status == TransferStatus.running ||
                          t.status == TransferStatus.queued)
                        LinearProgressIndicator(value: t.progress),
                      if (t.status == TransferStatus.failed)
                        Text(
                          'Failed: ${t.error}',
                          style: const TextStyle(color: Colors.red),
                        ),
                    ],
                  ),
                  trailing: switch (t.status) {
                    TransferStatus.running ||
                    TransferStatus.queued => IconButton(
                      icon: const Icon(Icons.cancel_outlined),
                      onPressed: () => ref
                          .read(transferManagerProvider.notifier)
                          .cancel(t.id),
                    ),
                    TransferStatus.done when t.type == TransferType.download =>
                      IconButton(
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () => OpenFilex.open(t.localPath),
                      ),
                    _ => Icon(
                      t.status == TransferStatus.done
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                    ),
                  },
                );
              },
            ),
    );
  }
}
