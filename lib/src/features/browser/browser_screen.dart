// Object browser: folder navigation, upload/download, share, CRUD.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/s3/s3_client.dart';
import '../../core/s3/s3_models.dart';
import '../../core/storage/account_store.dart';
import '../../ui/glass.dart';
import '../../ui/theme.dart';
import '../transfers/transfer_manager.dart';
import '../viewers/viewer_kind.dart';

class BrowserScreen extends ConsumerStatefulWidget {
  final String accountId;
  final String bucket;
  final String initialPrefix;
  const BrowserScreen({
    super.key,
    required this.accountId,
    required this.bucket,
    this.initialPrefix = '',
  });

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserState();
}

class _BrowserState extends ConsumerState<BrowserScreen> {
  String _prefix = '';
  late Future<ListObjectsResult> _future;
  String _filter = '';
  bool _uploading = false;
  bool _loadingMore = false;
  Timer? _filterDebounce;
  final _filterController = TextEditingController();

  // Sort: 0 = name, 1 = size desc, 2 = newest first.
  int _sort = 0;

  @override
  void initState() {
    super.initState();
    _prefix = widget.initialPrefix;
    _future = _load();
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    _filterController.dispose();
    super.dispose();
  }

  void _onFilterChanged(String v) {
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _filter = v.toLowerCase());
    });
  }

  Future<ListObjectsResult> _load() async {
    final account = ref.read(accountByIdProvider(widget.accountId));
    if (account == null) throw StateError('Account not found');
    final client = S3Client(account);
    try {
      return await client.listObjectsV2(widget.bucket, prefix: _prefix);
    } finally {
      client.close();
    }
  }

  Future<void> _loadMore(ListObjectsResult current) async {
    final token = current.nextContinuationToken;
    if (current.isTruncated != true || token == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final account = ref.read(accountByIdProvider(widget.accountId));
      if (account == null) return;
      final client = S3Client(account);
      try {
        final next = await client.listObjectsV2(
          widget.bucket,
          prefix: _prefix,
          continuationToken: token,
        );
        if (!mounted) return;
        final merged = ListObjectsResult(
          prefixes: [...current.prefixes, ...next.prefixes],
          objects: [...current.objects, ...next.objects],
          isTruncated: next.isTruncated,
          nextContinuationToken: next.nextContinuationToken,
          prefix: _prefix,
        ).sorted();
        setState(() => _future = Future.value(merged));
      } finally {
        client.close();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Load more failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  List<S3Object> _sortedObjects(List<S3Object> objects) {
    final list = List<S3Object>.of(objects);
    switch (_sort) {
      case 1:
        list.sort((a, b) => b.size.compareTo(a.size));
      case 2:
        list.sort((a, b) {
          final am = a.lastModified;
          final bm = b.lastModified;
          if (am == null && bm == null) return 0;
          if (am == null) return 1;
          if (bm == null) return -1;
          return bm.compareTo(am);
        });
      default:
        list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    }
    return list;
  }

  void _refresh() => setState(() => _future = _load());

  void _enterPrefix(String prefix) {
    _filterDebounce?.cancel();
    _filterController.clear();
    setState(() {
      _prefix = prefix;
      _filter = '';
      _future = _load();
    });
  }

  void _up() {
    if (_prefix.isEmpty) return;
    final trimmed = _prefix.endsWith('/')
        ? _prefix.substring(0, _prefix.length - 1)
        : _prefix;
    final idx = trimmed.lastIndexOf('/');
    _enterPrefix(idx == -1 ? '' : trimmed.substring(0, idx + 1));
  }

  List<String> get _crumbs {
    if (_prefix.isEmpty) return [];
    return _prefix.split('/').where((s) => s.isNotEmpty).toList();
  }

  String _prefixForCrumb(int index) {
    final parts = _crumbs.sublist(0, index + 1);
    return '${parts.join('/')}/';
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var u = -1;
    do {
      v /= 1024;
      u++;
    } while (v >= 1024 && u < units.length - 1);
    return '${v.toStringAsFixed(1)} ${units[u]}';
  }

  Future<void> _upload() async {
    // file_picker v12: static API returns nullable List<PlatformFile>.
    final dynamic picked = await FilePicker.pickFiles();
    if (picked == null) return;
    final List files = picked is List ? picked : (picked.files as List);
    if (files.isEmpty) return;
    setState(() => _uploading = true);
    try {
      final manager = ref.read(transferManagerProvider.notifier);
      var queued = 0;
      for (final f in files) {
        final path = (f as dynamic).path as String?;
        if (path == null) continue;
        await manager.enqueueUpload(
          accountId: widget.accountId,
          bucket: widget.bucket,
          prefix: _prefix,
          localPath: path,
        );
        queued++;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$queued upload(s) queued — see Transfers')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _download(S3Object obj) async {
    try {
      final id = await ref
          .read(transferManagerProvider.notifier)
          .enqueueDownload(
            accountId: widget.accountId,
            bucket: widget.bucket,
            key: obj.key,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Downloading ${obj.name}…'),
            action: SnackBarAction(
              label: 'Open file',
              onPressed: () async {
                // Poll briefly for completion instead of a fixed delay.
                for (var i = 0; i < 30; i++) {
                  await Future.delayed(const Duration(seconds: 1));
                  if (!mounted && !context.mounted) return;
                  final tasks = ref.read(transferManagerProvider);
                  TransferTask? task;
                  try {
                    task = tasks.firstWhere((t) => t.id == id);
                  } catch (_) {
                    return;
                  }
                  if (task.status == TransferStatus.done) {
                    await OpenFilex.open(task.localPath);
                    return;
                  }
                  if (task.status == TransferStatus.failed ||
                      task.status == TransferStatus.canceled) {
                    return;
                  }
                }
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
  }

  Future<void> _shareLink(S3Object obj) async {
    final account = ref.read(accountByIdProvider(widget.accountId))!;
    final client = S3Client(account);
    try {
      final url = client.presignedGet(
        widget.bucket,
        obj.key,
        expiresSeconds: 3600,
      );
      // share_plus v13 API (Share deprecated since v11).
      await SharePlus.instance.share(
        ShareParams(text: url.toString(), subject: obj.name),
      );
    } finally {
      client.close();
    }
  }

  Future<void> _delete(S3Object obj) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete "${obj.name}"?'),
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
        await client.deleteObject(widget.bucket, obj.key);
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

  Future<void> _rename(S3Object obj) async {
    final controller = TextEditingController(text: obj.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == obj.name) return;
    final dir = obj.key.contains('/')
        ? obj.key.substring(0, obj.key.lastIndexOf('/') + 1)
        : '';
    try {
      final account = ref.read(accountByIdProvider(widget.accountId))!;
      final client = S3Client(account);
      try {
        await client.moveObject(widget.bucket, obj.key, '$dir$newName');
      } finally {
        client.close();
      }
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Rename failed: $e')));
      }
    }
  }

  Future<void> _newFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'photos',
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
        await client.createFolder(widget.bucket, '$_prefix$name');
      } finally {
        client.close();
      }
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Create failed: $e')));
      }
    }
  }

  /// Open with the matching in-app viewer, or fall back to the action sheet.
  Future<void> _openObject(S3Object obj) async {
    final kind = viewerKindForKey(obj.key);
    if (kind == null) {
      _showObjectSheet(obj);
      return;
    }
    final route = switch (kind) {
      ViewerKind.image => '/view/image',
      ViewerKind.text => '/view/text',
      ViewerKind.pdf => '/view/pdf',
      ViewerKind.video => '/view/video',
    };
    final changed = await context.push<bool>(
      Uri(
        path: route,
        queryParameters: {
          'accountId': widget.accountId,
          'bucket': widget.bucket,
          'key': obj.key,
        },
      ).toString(),
    );
    // Text editor pops true after save → refresh the listing.
    if (changed == true && mounted) _refresh();
  }

  void _showObjectSheet(S3Object obj) {
    final date = obj.lastModified == null
        ? '—'
        : DateFormat.yMMMd().add_jm().format(obj.lastModified!.toLocal());
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(
                obj.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text('${formatBytes(obj.size)} • $date\n${obj.key}'),
              isThreeLine: true,
            ),
            const Divider(height: 1),
            if (viewerKindForKey(obj.key) != null)
              ListTile(
                leading: const Icon(Icons.open_in_new_outlined),
                title: const Text('Open'),
                onTap: () {
                  Navigator.pop(c);
                  _openObject(obj);
                },
              ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Download'),
              onTap: () {
                Navigator.pop(c);
                _download(obj);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_outlined),
              title: const Text('Share link (1h)'),
              onTap: () {
                Navigator.pop(c);
                _shareLink(obj);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(c);
                _rename(obj);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(c);
                _delete(obj);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Auto-refresh listing when an upload for this bucket/prefix completes.
    ref.listen<List<TransferTask>>(transferManagerProvider, (prev, next) {
      if (!mounted) return;
      final prevDone = {
        for (final t in prev ?? const <TransferTask>[])
          if (t.status == TransferStatus.done) t.id,
      };
      final newlyDone = next.where(
        (t) =>
            t.status == TransferStatus.done &&
            !prevDone.contains(t.id) &&
            t.type == TransferType.upload &&
            t.accountId == widget.accountId &&
            t.bucket == widget.bucket &&
            t.key.startsWith(_prefix),
      );
      if (newlyDone.isNotEmpty) _refresh();
    });
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          widget.bucket,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'New folder',
            onPressed: _newFolder,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(132),
          child: Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    ActionChip(
                      label: Text(widget.bucket),
                      avatar: const Icon(Icons.storage, size: 16),
                      onPressed: () => _enterPrefix(''),
                    ),
                    for (var i = 0; i < _crumbs.length; i++) ...[
                      const Text(' / '),
                      ActionChip(
                        label: Text(_crumbs[i]),
                        onPressed: () => _enterPrefix(_prefixForCrumb(i)),
                      ),
                    ],
                    if (_prefix.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.arrow_upward, size: 18),
                        tooltip: 'Up one level',
                        onPressed: _up,
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _filterController,
                        decoration: const InputDecoration(
                          hintText: 'Filter in this folder…',
                          prefixIcon: Icon(Icons.search_rounded),
                          isDense: true,
                        ),
                        onChanged: _onFilterChanged,
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<int>(
                      value: _sort,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('Name')),
                        DropdownMenuItem(value: 1, child: Text('Size')),
                        DropdownMenuItem(value: 2, child: Text('Newest')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _sort = v);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: FutureBuilder<ListObjectsResult>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not list objects',
                  subtitle: '${snap.error}',
                  action: GlowButton(
                    label: 'Retry',
                    icon: Icons.refresh_rounded,
                    onPressed: _refresh,
                  ),
                );
              }
              final result = snap.data!;
              final prefixes = result.prefixes
                  .where(
                    (p) => _filter.isEmpty || p.toLowerCase().contains(_filter),
                  )
                  .toList();
              final objects = _sortedObjects(
                result.objects
                    .where(
                      (o) =>
                          _filter.isEmpty ||
                          o.name.toLowerCase().contains(_filter) ||
                          o.key.toLowerCase().contains(_filter),
                    )
                    .toList(),
              );
              if (prefixes.isEmpty && objects.isEmpty) {
                return EmptyState(
                  icon: Icons.folder_open_rounded,
                  title: 'Empty folder',
                  subtitle: 'Upload files or create a folder to begin.',
                  action: GlowButton(
                    label: 'Upload',
                    icon: Icons.upload_rounded,
                    onPressed: _uploading ? null : _upload,
                  ),
                );
              }
              return RefreshIndicator(
                onRefresh: () async => _refresh(),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  children: [
                    for (final p in prefixes) ...[
                      _FolderCard(
                        prefix: p,
                        prefixBase: _prefix,
                        onTap: () => _enterPrefix(p),
                      ),
                      const SizedBox(height: 10),
                    ],
                    for (final obj in objects) ...[
                      _ObjectCard(
                        obj: obj,
                        scheme: scheme,
                        onTap: () => _openObject(obj),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (result.isTruncated) ...[
                      const SizedBox(height: 4),
                      Center(
                        child: _loadingMore
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(),
                              )
                            : OutlinedButton.icon(
                                onPressed: () => _loadMore(result),
                                icon: const Icon(Icons.expand_more_rounded),
                                label: const Text('Load more'),
                              ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _upload,
        icon: _uploading
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.upload),
        label: const Text('Upload'),
      ),
    );
  }
}

/// Glass folder row with gradient folder tile.
class _FolderCard extends StatelessWidget {
  final String prefix;
  final String prefixBase;
  final VoidCallback onTap;
  const _FolderCard({
    required this.prefix,
    required this.prefixBase,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = prefix.startsWith(prefixBase)
        ? prefix.substring(prefixBase.length).replaceAll('/', '')
        : prefix.replaceAll('/', '');
    return Glass(
      padding: const EdgeInsets.all(12),
      radius: 16,
      onTap: onTap,
      child: Row(
        children: [
          Container(
            height: 42,
            width: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              gradient: const LinearGradient(
                colors: [Color(0xFF38BDF8), AppColors.indigo],
              ),
            ),
            child: const Icon(
              Icons.folder_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name.isEmpty ? prefix : name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}

/// Glass file row with type-tinted icon, size, and viewer hint.
class _ObjectCard extends StatelessWidget {
  final S3Object obj;
  final ColorScheme scheme;
  final VoidCallback onTap;
  const _ObjectCard({
    required this.obj,
    required this.scheme,
    required this.onTap,
  });

  Color get _tint {
    final kind = viewerKindForKey(obj.key);
    return switch (kind) {
      ViewerKind.image => const Color(0xFF34D399),
      ViewerKind.video => const Color(0xFFF472B6),
      ViewerKind.pdf => const Color(0xFFF87171),
      ViewerKind.text => const Color(0xFF60A5FA),
      null => scheme.primary,
    };
  }

  IconData get _icon {
    final kind = viewerKindForKey(obj.key);
    return switch (kind) {
      ViewerKind.image => Icons.image_rounded,
      ViewerKind.video => Icons.movie_rounded,
      ViewerKind.pdf => Icons.picture_as_pdf_rounded,
      ViewerKind.text => Icons.description_rounded,
      null => Icons.insert_drive_file_rounded,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Glass(
      padding: const EdgeInsets.all(12),
      radius: 16,
      onTap: onTap,
      child: Row(
        children: [
          Container(
            height: 42,
            width: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              color: _tint.withValues(alpha: 0.18),
              border: Border.all(color: _tint.withValues(alpha: 0.35)),
            ),
            child: Icon(_icon, color: _tint, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  obj.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  _BrowserState.formatBytes(obj.size),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          if (viewerKindForKey(obj.key) != null)
            Icon(
              Icons.open_in_new_rounded,
              size: 18,
              color: scheme.onSurface.withValues(alpha: 0.4),
            ),
        ],
      ),
    );
  }
}
