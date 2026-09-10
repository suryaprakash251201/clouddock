// Object details: full HEAD metadata, custom x-amz-meta-*, tag editor,
// favorite toggle, and entry point to version history.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/prefs/app_prefs.dart';
import '../../core/s3/s3_client.dart';
import '../../core/s3/s3_exceptions.dart';
import '../../core/s3/s3_models.dart';
import '../../core/storage/account_store.dart';
import '../../core/utils/format.dart';
import '../../ui/file_visuals.dart';
import '../../ui/floating_nav_bar.dart';
import '../../ui/glass.dart';
import '../favorites/favorites_store.dart';
import '../transfers/transfer_manager.dart';
import '../viewers/viewer_routes.dart';

class ObjectDetailsScreen extends ConsumerStatefulWidget {
  final String accountId;
  final String bucket;
  final String objectKey;
  const ObjectDetailsScreen({
    super.key,
    required this.accountId,
    required this.bucket,
    required this.objectKey,
  });

  @override
  ConsumerState<ObjectDetailsScreen> createState() => _ObjectDetailsState();
}

class _DetailsBundle {
  final S3ObjectDetails details;
  final List<S3ObjectTag> tags;
  final String? tagsError;
  final BucketVersioning versioning;

  const _DetailsBundle({
    required this.details,
    required this.tags,
    this.tagsError,
    this.versioning = BucketVersioning.unknown,
  });
}

class _ObjectDetailsState extends ConsumerState<ObjectDetailsScreen> {
  late Future<_DetailsBundle> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  String get _name =>
      widget.objectKey.split('/').where((s) => s.isNotEmpty).lastOrNull ??
      widget.objectKey;

  String get _favoriteId =>
      FavoritesStore.idFor(widget.accountId, widget.bucket, widget.objectKey);

  Future<_DetailsBundle> _load() async {
    final account = ref.read(accountByIdProvider(widget.accountId));
    if (account == null) throw StateError('Account not found');
    final client = S3Client(account);
    try {
      final details = await client.headObjectDetails(
        widget.bucket,
        widget.objectKey,
      );
      if (details == null) throw StateError('Object not found');
      List<S3ObjectTag> tags = const [];
      String? tagsError;
      try {
        tags = await client.getObjectTags(widget.bucket, widget.objectKey);
      } on S3Exception catch (e) {
        tagsError = e.message;
      }
      var versioning = BucketVersioning.unknown;
      try {
        versioning = await client.getBucketVersioning(widget.bucket);
      } catch (_) {
        // Providers without versioning support: keep 'unknown'.
      }
      return _DetailsBundle(
        details: details,
        tags: tags,
        tagsError: tagsError,
        versioning: versioning,
      );
    } finally {
      client.close();
    }
  }

  void _refresh() => setState(() => _future = _load());

  void _snack(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _toggleFavorite(S3ObjectDetails details) async {
    final account = ref.read(accountByIdProvider(widget.accountId));
    final added = await ref
        .read(favoritesProvider.notifier)
        .toggle(
          accountId: widget.accountId,
          accountName: account?.name ?? '',
          bucket: widget.bucket,
          key: widget.objectKey,
          name: _name,
          size: details.size,
        );
    _snack(added ? 'Added to starred' : 'Removed from starred');
  }

  Future<void> _download() async {
    await ref
        .read(transferManagerProvider.notifier)
        .enqueueDownload(
          accountId: widget.accountId,
          bucket: widget.bucket,
          key: widget.objectKey,
        );
    _snack('Downloading $_name — see Downloads');
  }

  Future<void> _shareLink() async {
    final account = ref.read(accountByIdProvider(widget.accountId));
    if (account == null) return;
    final client = S3Client(account);
    try {
      final url = client.presignedGet(
        widget.bucket,
        widget.objectKey,
        expiresSeconds: ref.read(linkExpiryProvider),
      );
      await SharePlus.instance.share(
        ShareParams(text: url.toString(), subject: _name),
      );
    } finally {
      client.close();
    }
  }

  Future<void> _open() async {
    final route = viewerRouteForKey(widget.objectKey);
    if (route == null) {
      _snack('No in-app viewer for this file type — download it instead.');
      return;
    }
    await context.push(
      viewerLocation(
        route: route,
        accountId: widget.accountId,
        bucket: widget.bucket,
        key: widget.objectKey,
      ),
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete "$_name"?'),
        content: const Text('This cannot be undone.'),
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
        await client.deleteObject(widget.bucket, widget.objectKey);
      } finally {
        client.close();
      }
      await ref.read(favoritesProvider.notifier).remove(_favoriteId);
      if (mounted) context.pop(true);
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  Future<void> _editTags(List<S3ObjectTag> current) async {
    final edited = await showModalBottomSheet<List<S3ObjectTag>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TagEditorSheet(initial: current),
    );
    if (edited == null || !mounted) return;
    try {
      final account = ref.read(accountByIdProvider(widget.accountId))!;
      final client = S3Client(account);
      try {
        await client.putObjectTags(widget.bucket, widget.objectKey, edited);
      } finally {
        client.close();
      }
      _snack('Tags saved');
      _refresh();
    } catch (e) {
      _snack('Could not save tags: $e');
    }
  }

  void _openVersions() {
    context.push(
      Uri(
        path: '/s3/versions',
        queryParameters: {
          'accountId': widget.accountId,
          'bucket': widget.bucket,
          'key': widget.objectKey,
        },
      ).toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final starred = ref.watch(
      favoritesProvider.select((list) => list.any((f) => f.id == _favoriteId)),
    );
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: Icon(
              starred ? Icons.star_rounded : Icons.star_outline_rounded,
              color: starred ? const Color(0xFFFBBF24) : null,
            ),
            tooltip: starred ? 'Remove from starred' : 'Add to starred',
            onPressed: () async {
              try {
                final bundle = await _future;
                await _toggleFavorite(bundle.details);
              } catch (_) {
                // Loading failed; the body already shows the error.
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: AppBackground(
        child: SafeArea(
          child: FutureBuilder<_DetailsBundle>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not load details',
                  subtitle: '${snap.error}',
                  action: GlowButton(
                    label: 'Retry',
                    icon: Icons.refresh_rounded,
                    onPressed: _refresh,
                  ),
                );
              }
              final bundle = snap.data!;
              final d = bundle.details;
              final tint = fileTint(widget.objectKey, scheme.primary);
              return ListView(
                padding: const EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  kFloatingNavBarClearance,
                ),
                children: [
                  Glass(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Container(
                          height: 56,
                          width: 56,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(17),
                            color: tint.withValues(alpha: 0.18),
                            border: Border.all(
                              color: tint.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Icon(
                            fileIcon(widget.objectKey),
                            color: tint,
                            size: 28,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${formatBytes(d.size)} • ${_date(d.lastModified)}',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SectionLabel('Actions'),
                  Glass(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.open_in_new_rounded),
                          title: const Text('Open'),
                          enabled: viewerRouteForKey(widget.objectKey) != null,
                          onTap: _open,
                        ),
                        ListTile(
                          leading: const Icon(Icons.download_outlined),
                          title: const Text('Download'),
                          onTap: _download,
                        ),
                        ListTile(
                          leading: const Icon(Icons.link_outlined),
                          title: Text(
                            'Share link (${describeExpiry(ref.read(linkExpiryProvider))})',
                          ),
                          onTap: _shareLink,
                        ),
                        ListTile(
                          leading: const Icon(Icons.content_copy_rounded),
                          title: const Text('Copy key path'),
                          onTap: () async {
                            await Clipboard.setData(
                              ClipboardData(text: widget.objectKey),
                            );
                            _snack('Key path copied');
                          },
                        ),
                      ],
                    ),
                  ),
                  const SectionLabel('Properties'),
                  Glass(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Column(
                      children: [
                        _PropertyRow(label: 'Bucket', value: widget.bucket),
                        _PropertyRow(label: 'Key', value: widget.objectKey),
                        _PropertyRow(label: 'Size', value: formatBytes(d.size)),
                        _PropertyRow(
                          label: 'Content type',
                          value: d.contentType,
                        ),
                        _PropertyRow(label: 'ETag', value: d.etag),
                        _PropertyRow(
                          label: 'Storage class',
                          value: d.storageClass,
                        ),
                        _PropertyRow(label: 'Version ID', value: d.versionId),
                        _PropertyRow(
                          label: 'Last modified',
                          value: _date(d.lastModified, withTime: true),
                        ),
                        _PropertyRow(
                          label: 'Cache-Control',
                          value: d.cacheControl,
                        ),
                        _PropertyRow(
                          label: 'Content disposition',
                          value: d.contentDisposition,
                        ),
                        _PropertyRow(
                          label: 'Content encoding',
                          value: d.contentEncoding,
                        ),
                      ],
                    ),
                  ),
                  if (d.hasMetadata) ...[
                    const SectionLabel('Custom metadata'),
                    Glass(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Column(
                        children: [
                          for (final e in d.metadata.entries)
                            _PropertyRow(label: e.key, value: e.value),
                        ],
                      ),
                    ),
                  ],
                  SectionLabel('Tags (${bundle.tags.length})'),
                  Glass(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (bundle.tagsError != null)
                          Text(
                            bundle.tagsError!,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.error,
                            ),
                          )
                        else if (bundle.tags.isEmpty)
                          Text(
                            'No tags on this object.',
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurface.withValues(alpha: 0.6),
                            ),
                          )
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final t in bundle.tags)
                                Chip(label: Text('${t.key}: ${t.value}')),
                            ],
                          ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => _editTags(bundle.tags),
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('Edit tags'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SectionLabel('History'),
                  Glass(
                    padding: const EdgeInsets.all(6),
                    child: ListTile(
                      leading: const Icon(Icons.history_rounded),
                      title: const Text('Version history'),
                      subtitle: Text(switch (bundle.versioning) {
                        BucketVersioning.enabled => 'Versioning enabled',
                        BucketVersioning.suspended => 'Versioning suspended',
                        BucketVersioning.unversioned =>
                          'Versioning is off for this bucket',
                        BucketVersioning.unknown => 'List object versions',
                      }),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _openVersions,
                    ),
                  ),
                  const SectionLabel('Danger zone'),
                  Glass(
                    padding: const EdgeInsets.all(6),
                    child: ListTile(
                      leading: Icon(
                        Icons.delete_outline_rounded,
                        color: scheme.error,
                      ),
                      title: Text(
                        'Delete object',
                        style: TextStyle(color: scheme.error),
                      ),
                      onTap: _delete,
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

  static String _date(DateTime? value, {bool withTime = false}) {
    if (value == null) return '—';
    final local = value.toLocal();
    return withTime
        ? DateFormat.yMMMd().add_jm().format(local)
        : DateFormat.yMMMd().format(local);
  }
}

class _PropertyRow extends StatelessWidget {
  final String label;
  final String? value;
  const _PropertyRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              (value == null || value!.isEmpty) ? '—' : value!,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet that edits a tag set and pops the new list.
class _TagEditorSheet extends StatefulWidget {
  final List<S3ObjectTag> initial;
  const _TagEditorSheet({required this.initial});

  @override
  State<_TagEditorSheet> createState() => _TagEditorSheetState();
}

class _TagEditorSheetState extends State<_TagEditorSheet> {
  late final List<_TagRow> _rows = widget.initial
      .map((t) => _TagRow(t.key, t.value))
      .toList();

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  List<S3ObjectTag> get _tags => [
    for (final r in _rows)
      if (r.key.text.trim().isNotEmpty)
        S3ObjectTag(r.key.text.trim(), r.value.text),
  ];

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Edit tags',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'Key/value pairs stored with the object. Empty keys are ignored. '
            'AWS S3 allows up to 10 tags per object.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _rows.length,
              itemBuilder: (c, i) {
                final row = _rows[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: row.key,
                          decoration: const InputDecoration(
                            labelText: 'Key',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: row.value,
                          decoration: const InputDecoration(
                            labelText: 'Value',
                            isDense: true,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline_rounded),
                        tooltip: 'Remove tag',
                        onPressed: () {
                          setState(() {
                            _rows.removeAt(i).dispose();
                          });
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _rows.add(_TagRow('', ''))),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add tag'),
              ),
              const Spacer(),
              GlowButton(
                label: 'Save',
                icon: Icons.check_rounded,
                onPressed: () => Navigator.pop(context, _tags),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TagRow {
  final TextEditingController key;
  final TextEditingController value;
  _TagRow(String k, String v)
    : key = TextEditingController(text: k),
      value = TextEditingController(text: v);

  void dispose() {
    key.dispose();
    value.dispose();
  }
}
