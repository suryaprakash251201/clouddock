// Object browser: folder navigation, upload/download, share, CRUD.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/s3/s3_client.dart';
import '../../core/s3/s3_models.dart';
import '../../core/storage/account_store.dart';
import '../transfers/transfer_manager.dart';

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

  @override
  void initState() {
    super.initState();
    _prefix = widget.initialPrefix;
    _future = _load();
  }

  Future<ListObjectsResult> _load() async {
    final account = ref.read(accountByIdProvider(widget.accountId));
    if (account == null) throw StateError('Account not found');
    final client = S3Client(account);
    try {
      // Load first page; paginate on demand via "load more" is V2.
      // For now pull up to ~3 pages to keep UX simple.
      var result = await client.listObjectsV2(widget.bucket, prefix: _prefix);
      if (result.isTruncated && result.nextContinuationToken != null) {
        final second = await client.listObjectsV2(
          widget.bucket,
          prefix: _prefix,
          continuationToken: result.nextContinuationToken,
        );
        result = ListObjectsResult(
          prefixes: [...result.prefixes, ...second.prefixes],
          objects: [...result.objects, ...second.objects],
          isTruncated: second.isTruncated,
          nextContinuationToken: second.nextContinuationToken,
          prefix: _prefix,
        ).sorted();
      }
      return result;
    } finally {
      client.close();
    }
  }

  void _refresh() => setState(() => _future = _load());

  void _enterPrefix(String prefix) {
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
    _enterPrefix(idx == -1 ? '' : '${trimmed.substring(0, idx + 1)}');
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
    final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (picked == null || picked.files.isEmpty) return;
    setState(() => _uploading = true);
    try {
      final manager = ref.read(transferManagerProvider.notifier);
      for (final f in picked.files) {
        final path = f.path;
        if (path == null) continue;
        await manager.enqueueUpload(
          accountId: widget.accountId,
          bucket: widget.bucket,
          prefix: _prefix,
          localPath: path,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Upload queued — see Transfers')),
        );
      }
      // Refresh after a beat so small uploads appear.
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) _refresh();
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
                // Wait briefly then try to open the completed file.
                await Future.delayed(const Duration(seconds: 1));
                final tasks = ref.read(transferManagerProvider);
                final task = tasks.firstWhere((t) => t.id == id);
                await OpenFilex.open(task.localPath);
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
      await Share.share(url.toString(), subject: obj.name);
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

  IconData _iconFor(S3Object obj) {
    final ext = obj.extension;
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'].contains(ext)) {
      return Icons.image_outlined;
    }
    if (['mp4', 'mov', 'mkv', 'webm'].contains(ext)) {
      return Icons.movie_outlined;
    }
    if (['mp3', 'wav', 'flac', 'm4a'].contains(ext)) {
      return Icons.audio_file_outlined;
    }
    if (['pdf'].contains(ext)) return Icons.picture_as_pdf_outlined;
    if (['zip', 'tar', 'gz', 'rar', '7z'].contains(ext)) {
      return Icons.folder_zip_outlined;
    }
    if (['txt', 'md', 'json', 'xml', 'csv', 'log'].contains(ext)) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.bucket),
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
          preferredSize: const Size.fromHeight(96),
          child: Column(
            children: [
              if (_prefix.isNotEmpty || true)
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
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Filter in this folder…',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _filter = v.toLowerCase()),
                ),
              ),
            ],
          ),
        ),
      ),
      body: FutureBuilder<ListObjectsResult>(
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
          final result = snap.data!;
          final prefixes = result.prefixes
              .where(
                (p) => _filter.isEmpty || p.toLowerCase().contains(_filter),
              )
              .toList();
          final objects = result.objects
              .where(
                (o) =>
                    _filter.isEmpty ||
                    o.name.toLowerCase().contains(_filter) ||
                    o.key.toLowerCase().contains(_filter),
              )
              .toList();
          if (prefixes.isEmpty && objects.isEmpty) {
            return const Center(
              child: Text('Empty folder. Upload files or create a folder.'),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView.separated(
              itemCount: prefixes.length + objects.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                if (i < prefixes.length) {
                  final p = prefixes[i];
                  final name = p.substring(_prefix.length).replaceAll('/', '');
                  return ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(name.isEmpty ? p : name),
                    onTap: () => _enterPrefix(p),
                  );
                }
                final obj = objects[i - prefixes.length];
                return ListTile(
                  leading: Icon(_iconFor(obj)),
                  title: Text(obj.name),
                  subtitle: Text(formatBytes(obj.size)),
                  trailing: const Icon(Icons.more_vert),
                  onTap: () => _showObjectSheet(obj),
                );
              },
            ),
          );
        },
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
