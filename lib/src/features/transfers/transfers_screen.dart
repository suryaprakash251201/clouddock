// Transfer queue: glass rows with status pills and rounded progress.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../../ui/glass.dart';
import 'transfer_manager.dart';

class TransfersScreen extends ConsumerWidget {
  const TransfersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(transferManagerProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          'Transfers',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
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
      body: AppBackground(
        child: SafeArea(
          child: tasks.isEmpty
              ? const EmptyState(
                  icon: Icons.sync_rounded,
                  title: 'No transfers yet',
                  subtitle: 'Uploads and downloads will appear here with live progress.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    const SectionLabel('Queue'),
                    for (final t in tasks) ...[
                      Glass(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Container(
                              height: 44,
                              width: 44,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                gradient: LinearGradient(
                                  colors: [
                                    scheme.primary.withValues(alpha: 0.8),
                                    scheme.secondary.withValues(alpha: 0.8),
                                  ],
                                ),
                              ),
                              child: Icon(
                                t.type == TransferType.upload
                                    ? Icons.upload_rounded
                                    : Icons.download_rounded,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          t.key.split('/').last,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      StatusPill(
                                        label: _label(t.status),
                                        color: _color(t.status, scheme),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${t.bucket} • ${(t.progress * 100).toStringAsFixed(0)}%',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurface.withValues(
                                        alpha: 0.6,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  if (t.status == TransferStatus.running ||
                                      t.status == TransferStatus.queued)
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(99),
                                      child: LinearProgressIndicator(
                                        value: t.progress,
                                        minHeight: 6,
                                      ),
                                    ),
                                  if (t.status == TransferStatus.failed)
                                    Text(
                                      'Failed: ${t.error}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.error,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 4),
                            switch (t.status) {
                              TransferStatus.running ||
                              TransferStatus.queued => IconButton(
                                icon: const Icon(Icons.cancel_outlined),
                                onPressed: () => ref
                                    .read(transferManagerProvider.notifier)
                                    .cancel(t.id),
                              ),
                              TransferStatus.done
                                  when t.type == TransferType.download =>
                                IconButton(
                                  icon: const Icon(Icons.open_in_new_rounded),
                                  onPressed: () => OpenFilex.open(t.localPath),
                                ),
                              _ => Icon(
                                t.status == TransferStatus.done
                                    ? Icons.check_circle_rounded
                                    : Icons.error_outline_rounded,
                                color: _color(t.status, scheme),
                              ),
                            },
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  String _label(TransferStatus s) => switch (s) {
    TransferStatus.queued => 'Queued',
    TransferStatus.running => 'Active',
    TransferStatus.done => 'Done',
    TransferStatus.failed => 'Failed',
    TransferStatus.canceled => 'Canceled',
  };

  Color _color(TransferStatus s, ColorScheme scheme) => switch (s) {
    TransferStatus.done => Colors.green,
    TransferStatus.failed => scheme.error,
    TransferStatus.canceled => Colors.grey,
    _ => scheme.primary,
  };
}
