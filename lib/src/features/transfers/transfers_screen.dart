// Transfer queue: grouped Active / Finished rows with progress, retry,
// open/share/delete-local actions.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/utils/format.dart';
import '../../ui/floating_nav_bar.dart';
import '../../ui/glass.dart';
import 'transfer_manager.dart';

class TransfersScreen extends ConsumerWidget {
  const TransfersScreen({super.key});

  static String _formatBytes(int? bytes) => formatBytes(bytes);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(transferManagerProvider);
    final notifier = ref.read(transferManagerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final active = tasks
        .where(
          (t) =>
              t.status == TransferStatus.queued ||
              t.status == TransferStatus.running,
        )
        .toList();
    final finished = tasks
        .where(
          (t) =>
              t.status == TransferStatus.done ||
              t.status == TransferStatus.failed ||
              t.status == TransferStatus.canceled,
        )
        .toList();

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          'Downloads',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (finished.any(
            (t) =>
                t.status == TransferStatus.failed ||
                t.status == TransferStatus.canceled,
          ))
            TextButton(
              onPressed: () => notifier.retryAllFailed(),
              child: const Text('Retry all'),
            ),
          if (finished.isNotEmpty)
            TextButton(
              onPressed: () => notifier.clearFinished(),
              child: const Text('Clear'),
            ),
          if (tasks.any((t) => t.status == TransferStatus.failed))
            TextButton(
              onPressed: () => notifier.clearFailed(),
              child: const Text('Clear failed'),
            ),
        ],
      ),
      body: AppBackground(
        child: SafeArea(
          child: tasks.isEmpty
              ? const EmptyState(
                  icon: Icons.download_rounded,
                  title: 'No transfers yet',
                  subtitle: 'Uploads and downloads will appear here with live progress. Files you download stay on-device.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(
                    16,
                    8,
                    16,
                    kFloatingNavBarClearance,
                  ),
                  children: [
                    if (active.isNotEmpty) ...[
                      SectionLabel('Active (${active.length})'),
                      for (final t in active) ...[
                        _TransferCard(task: t, scheme: scheme),
                        const SizedBox(height: 12),
                      ],
                    ],
                    if (finished.isNotEmpty) ...[
                      SectionLabel('Finished (${finished.length})'),
                      for (final t in finished) ...[
                        Dismissible(
                          key: ValueKey(t.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            decoration: BoxDecoration(
                              color: scheme.error.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Icon(Icons.delete_outline_rounded),
                          ),
                          onDismissed: (_) => notifier.remove(t.id),
                          child: _TransferCard(task: t, scheme: scheme),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

class _TransferCard extends ConsumerWidget {
  final TransferTask task;
  final ColorScheme scheme;
  const _TransferCard({required this.task, required this.scheme});

  String _label(TransferStatus s) => switch (s) {
    TransferStatus.queued => 'Queued',
    TransferStatus.running => 'Active',
    TransferStatus.done => 'Done',
    TransferStatus.failed => 'Failed',
    TransferStatus.canceled => 'Canceled',
  };

  Color _color(TransferStatus s) => switch (s) {
    TransferStatus.done => Colors.green,
    TransferStatus.failed => scheme.error,
    TransferStatus.canceled => Colors.grey,
    _ => scheme.primary,
  };

  Future<void> _shareLocal(BuildContext context) async {
    final file = File(task.localPath);
    if (!await file.exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Local file not found')));
      }
      return;
    }
    await SharePlus.instance.share(ShareParams(files: [XFile(task.localPath)]));
  }

  Future<void> _deleteLocal(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete local file?'),
        content: Text(task.localPath),
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
    if (ok == true) {
      await ref
          .read(transferManagerProvider.notifier)
          .remove(task.id, deleteLocalFile: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = task;
    final notifier = ref.read(transferManagerProvider.notifier);
    final sizeStr = TransfersScreen._formatBytes(t.totalBytes);
    return Glass(
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
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    StatusPill(
                      label: _label(t.status),
                      color: _color(t.status),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    t.bucket,
                    '${(t.progress * 100).toStringAsFixed(0)}%',
                    if (sizeStr.isNotEmpty) sizeStr,
                    if (t.type == TransferType.download) 'on-device',
                  ].join(' • '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 8),
                if (t.status == TransferStatus.running ||
                    t.status == TransferStatus.queued)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: t.progress == 0 ? null : t.progress,
                      minHeight: 6,
                    ),
                  ),
                if (t.status == TransferStatus.failed)
                  Text(
                    'Failed: ${t.error}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                if (t.status == TransferStatus.done &&
                    t.type == TransferType.download)
                  Text(
                    t.localPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withValues(alpha: 0.45),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          switch (t.status) {
            TransferStatus.running || TransferStatus.queued => IconButton(
              icon: const Icon(Icons.cancel_outlined),
              tooltip: 'Cancel',
              onPressed: () => notifier.cancel(t.id),
            ),
            TransferStatus.done when t.type == TransferType.download =>
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: (v) async {
                  if (v == 'open') {
                    await OpenFilex.open(t.localPath);
                  } else if (v == 'share') {
                    if (context.mounted) await _shareLocal(context);
                  } else if (v == 'delete') {
                    if (context.mounted) await _deleteLocal(context, ref);
                  } else if (v == 'dismiss') {
                    await notifier.remove(t.id);
                  }
                },
                itemBuilder: (c) => const [
                  PopupMenuItem(value: 'open', child: Text('Open file')),
                  PopupMenuItem(value: 'share', child: Text('Share file')),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete local file'),
                  ),
                  PopupMenuItem(value: 'dismiss', child: Text('Dismiss')),
                ],
              ),
            TransferStatus.failed || TransferStatus.canceled => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Retry',
                  onPressed: () => notifier.retry(t.id),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Dismiss',
                  onPressed: () => notifier.remove(t.id),
                ),
              ],
            ),
            _ => IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Dismiss',
              onPressed: () => notifier.remove(t.id),
            ),
          },
        ],
      ),
    );
  }
}
