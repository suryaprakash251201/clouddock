// Version history for one object: list, restore, download, share, and
// permanently delete specific versions.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/prefs/app_prefs.dart';
import '../../core/s3/s3_client.dart';
import '../../core/s3/s3_exceptions.dart';
import '../../core/s3/s3_models.dart';
import '../../core/storage/account_store.dart';
import '../../core/utils/format.dart';
import '../../ui/floating_nav_bar.dart';
import '../../ui/glass.dart';
import '../transfers/transfer_manager.dart';

class VersionsScreen extends ConsumerStatefulWidget {
  final String accountId;
  final String bucket;
  final String objectKey;
  const VersionsScreen({
    super.key,
    required this.accountId,
    required this.bucket,
    required this.objectKey,
  });

  @override
  ConsumerState<VersionsScreen> createState() => _VersionsState();
}

class _VersionsBundle {
  final BucketVersioning versioning;
  final List<S3ObjectVersion> versions;
  final bool isTruncated;
  final String? nextKeyMarker;
  final String? nextVersionIdMarker;

  /// Populated when ListObjectVersions is unsupported/failed.
  final String? error;

  const _VersionsBundle({
    required this.versioning,
    required this.versions,
    this.isTruncated = false,
    this.nextKeyMarker,
    this.nextVersionIdMarker,
    this.error,
  });
}

class _VersionsState extends ConsumerState<VersionsScreen> {
  late Future<_VersionsBundle> _future;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  String get _name => widget.objectKey.split('/').last;

  Future<_VersionsBundle> _load() async {
    final account = ref.read(accountByIdProvider(widget.accountId));
    if (account == null) throw StateError('Account not found');
    final client = S3Client(account);
    try {
      var versioning = BucketVersioning.unknown;
      try {
        versioning = await client.getBucketVersioning(widget.bucket);
      } catch (_) {
        // Some S3-compatible servers reject GetBucketVersioning.
      }
      try {
        final page = await client.listObjectVersions(
          widget.bucket,
          prefix: widget.objectKey,
        );
        return _VersionsBundle(
          versioning: versioning,
          versions: _exact(page.versions),
          isTruncated: page.isTruncated,
          nextKeyMarker: page.nextKeyMarker,
          nextVersionIdMarker: page.nextVersionIdMarker,
        );
      } on S3Exception catch (e) {
        // Not every S3-compatible server implements ListObjectVersions.
        return _VersionsBundle(
          versioning: versioning,
          versions: const [],
          error: e.message,
        );
      }
    } finally {
      client.close();
    }
  }

  List<S3ObjectVersion> _exact(List<S3ObjectVersion> versions) {
    final exact = versions.where((v) => v.key == widget.objectKey).toList();
    exact.sort((a, b) {
      final am = a.lastModified;
      final bm = b.lastModified;
      if (am == null && bm == null) return 0;
      if (am == null) return 1;
      if (bm == null) return -1;
      return bm.compareTo(am);
    });
    return exact;
  }

  void _refresh() => setState(() => _future = _load());

  void _snack(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _loadMore(_VersionsBundle current) async {
    final keyMarker = current.nextKeyMarker;
    final versionMarker = current.nextVersionIdMarker;
    if (!current.isTruncated || keyMarker == null || versionMarker == null) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final account = ref.read(accountByIdProvider(widget.accountId));
      if (account == null) return;
      final client = S3Client(account);
      try {
        final page = await client.listObjectVersions(
          widget.bucket,
          prefix: widget.objectKey,
          keyMarker: keyMarker,
          versionIdMarker: versionMarker,
        );
        if (!mounted) return;
        final merged = _VersionsBundle(
          versioning: current.versioning,
          versions: _exact([...current.versions, ...page.versions]),
          isTruncated: page.isTruncated,
          nextKeyMarker: page.nextKeyMarker,
          nextVersionIdMarker: page.nextVersionIdMarker,
        );
        setState(() => _future = Future.value(merged));
      } finally {
        client.close();
      }
    } catch (e) {
      _snack('Load more failed: $e');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _restore(S3ObjectVersion v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Restore this version?'),
        content: Text(
          'Version ${v.shortVersionId} (${_date(v.lastModified)}) will be '
          'copied over the current object. The current data stays available '
          'as a previous version.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final account = ref.read(accountByIdProvider(widget.accountId))!;
      final client = S3Client(account);
      try {
        await client.restoreObjectVersion(
          widget.bucket,
          widget.objectKey,
          v.versionId,
        );
      } finally {
        client.close();
      }
      _snack('Restored version ${v.shortVersionId}');
      _refresh();
    } catch (e) {
      _snack('Restore failed: $e');
    }
  }

  Future<void> _download(S3ObjectVersion v) async {
    await ref
        .read(transferManagerProvider.notifier)
        .enqueueDownload(
          accountId: widget.accountId,
          bucket: widget.bucket,
          key: widget.objectKey,
          versionId: v.versionId,
        );
    _snack('Downloading $_name (v${v.shortVersionId}) — see Downloads');
  }

  Future<void> _share(S3ObjectVersion v) async {
    final account = ref.read(accountByIdProvider(widget.accountId));
    if (account == null) return;
    final client = S3Client(account);
    try {
      final url = client.presignedGet(
        widget.bucket,
        widget.objectKey,
        versionId: v.versionId,
        expiresSeconds: ref.read(linkExpiryProvider),
      );
      await SharePlus.instance.share(
        ShareParams(text: url.toString(), subject: _name),
      );
    } finally {
      client.close();
    }
  }

  Future<void> _deleteVersion(S3ObjectVersion v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this version?'),
        content: Text(
          'Version ${v.shortVersionId} will be permanently deleted. '
          'This cannot be undone.',
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
    if (ok != true) return;
    try {
      final account = ref.read(accountByIdProvider(widget.accountId))!;
      final client = S3Client(account);
      try {
        await client.deleteObject(
          widget.bucket,
          widget.objectKey,
          versionId: v.versionId,
        );
      } finally {
        client.close();
      }
      _snack('Version ${v.shortVersionId} deleted');
      _refresh();
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          'Versions • $_name',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: AppBackground(
        child: SafeArea(
          child: FutureBuilder<_VersionsBundle>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not list versions',
                  subtitle: '${snap.error}',
                  action: GlowButton(
                    label: 'Retry',
                    icon: Icons.refresh_rounded,
                    onPressed: _refresh,
                  ),
                );
              }
              final bundle = snap.data!;
              if (bundle.versions.isEmpty) {
                return EmptyState(
                  icon: Icons.history_rounded,
                  title: 'No version history',
                  subtitle:
                      bundle.error ??
                      switch (bundle.versioning) {
                        BucketVersioning.enabled =>
                          'No versions were returned for this object.',
                        BucketVersioning.suspended => 'Versioning is suspended and no versions exist for this object.',
                        _ => 'Versioning is not enabled on this bucket. Enable it to keep previous object revisions.',
                      },
                  action: GlowButton(
                    label: 'Refresh',
                    icon: Icons.refresh_rounded,
                    filled: false,
                    onPressed: _refresh,
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
                  Glass(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    radius: 16,
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 18,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            switch (bundle.versioning) {
                              BucketVersioning.enabled => 'Versioning is enabled — old versions count towards storage.',
                              BucketVersioning.suspended => 'Versioning is suspended. Existing versions are kept.',
                              _ => 'Versioning state unknown; versions below come from the server.',
                            },
                            style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SectionLabel('Versions (${bundle.versions.length})'),
                  for (final v in bundle.versions) ...[
                    _VersionCard(
                      version: v,
                      scheme: scheme,
                      onRestore: v.isRestorable ? () => _restore(v) : null,
                      onDownload: v.isRestorable ? () => _download(v) : null,
                      onShare: v.isRestorable ? () => _share(v) : null,
                      onDelete: () => _deleteVersion(v),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (bundle.isTruncated)
                    Center(
                      child: _loadingMore
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: CircularProgressIndicator(),
                            )
                          : OutlinedButton.icon(
                              onPressed: () => _loadMore(bundle),
                              icon: const Icon(Icons.expand_more_rounded),
                              label: const Text('Load more'),
                            ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static String _date(DateTime? value) {
    if (value == null) return 'Unknown date';
    return DateFormat.yMMMd().add_jm().format(value.toLocal());
  }
}

class _VersionCard extends StatelessWidget {
  final S3ObjectVersion version;
  final ColorScheme scheme;
  final VoidCallback? onRestore;
  final VoidCallback? onDownload;
  final VoidCallback? onShare;
  final VoidCallback onDelete;

  const _VersionCard({
    required this.version,
    required this.scheme,
    required this.onRestore,
    required this.onDownload,
    required this.onShare,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final v = version;
    final marker = v.isDeleteMarker;
    return Glass(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            height: 44,
            width: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: (marker ? scheme.error : scheme.primary).withValues(
                alpha: 0.16,
              ),
              border: Border.all(
                color: (marker ? scheme.error : scheme.primary).withValues(
                  alpha: 0.35,
                ),
              ),
            ),
            child: Icon(
              marker ? Icons.block_rounded : Icons.history_rounded,
              color: marker ? scheme.error : scheme.primary,
              size: 22,
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
                        'v${v.shortVersionId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    if (v.isLatest)
                      StatusPill(label: 'Latest', color: Colors.green),
                    if (marker) ...[
                      const SizedBox(width: 4),
                      StatusPill(label: 'Delete marker', color: scheme.error),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (!marker) formatBytes(v.size),
                    _VersionsState._date(v.lastModified),
                    if (v.storageClass != null && !marker) v.storageClass!,
                  ].join(' • '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (action) => switch (action) {
              'restore' => onRestore?.call(),
              'download' => onDownload?.call(),
              'share' => onShare?.call(),
              'delete' => onDelete(),
              _ => null,
            },
            itemBuilder: (c) => [
              PopupMenuItem(
                value: 'restore',
                enabled: onRestore != null,
                child: const Text('Restore this version'),
              ),
              PopupMenuItem(
                value: 'download',
                enabled: onDownload != null,
                child: const Text('Download'),
              ),
              PopupMenuItem(
                value: 'share',
                enabled: onShare != null,
                child: const Text('Share link'),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Text(marker ? 'Remove delete marker' : 'Delete version'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
