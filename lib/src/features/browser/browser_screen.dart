// Object browser: folder navigation, upload/download, share, CRUD,
// multi-select batch actions, and upload links.

import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/prefs/app_prefs.dart';
import '../../core/s3/s3_client.dart';
import '../../core/s3/s3_models.dart';
import '../../core/storage/account_store.dart';
import '../../core/utils/format.dart';
import '../../ui/file_visuals.dart';
import '../../ui/floating_nav_bar.dart';
import '../../ui/glass.dart';
import '../../ui/theme.dart';
import '../favorites/favorites_store.dart';
import '../home/recent_files_store.dart';
import '../transfers/transfer_manager.dart';
import '../viewers/viewer_kind.dart';
import '../viewers/viewer_routes.dart';

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

  // Multi-select mode.
  bool _selectionMode = false;
  final Set<String> _selectedKeys = {};

  /// Objects from the most recent successful listing (for Select all).
  List<S3Object> _visibleObjects = const [];

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
    // Selection mode may have hidden the shell's floating nav.
    ref.read(shellNavVisibleProvider.notifier).state = true;
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
    if (_selectionMode) {
      ref.read(shellNavVisibleProvider.notifier).state = true;
    }
    setState(() {
      _prefix = prefix;
      _filter = '';
      _selectionMode = false;
      _selectedKeys.clear();
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

  void _snack(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  // ---------- multi-select ----------

  void _enterSelection([S3Object? initial]) {
    ref.read(shellNavVisibleProvider.notifier).state = false;
    setState(() {
      _selectionMode = true;
      _selectedKeys.clear();
      if (initial != null) _selectedKeys.add(initial.key);
    });
  }

  void _exitSelection() {
    ref.read(shellNavVisibleProvider.notifier).state = true;
    setState(() {
      _selectionMode = false;
      _selectedKeys.clear();
    });
  }

  void _toggleSelected(S3Object obj) {
    setState(() {
      if (!_selectedKeys.add(obj.key)) _selectedKeys.remove(obj.key);
    });
  }

  List<S3Object> get _selectedObjects =>
      _visibleObjects.where((o) => _selectedKeys.contains(o.key)).toList();

  void _selectAll() {
    setState(() {
      if (_selectedKeys.length == _visibleObjects.length) {
        _selectedKeys.clear();
      } else {
        _selectedKeys
          ..clear()
          ..addAll(_visibleObjects.map((o) => o.key));
      }
    });
  }

  Future<void> _deleteSelected() async {
    final selected = _selectedObjects;
    if (selected.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${selected.length} object(s)?'),
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
        final keys = selected.map((o) => o.key).toList();
        const chunk = 1000; // S3 multi-delete limit per request.
        for (var i = 0; i < keys.length; i += chunk) {
          await client.deleteObjects(
            widget.bucket,
            keys.sublist(i, math.min(i + chunk, keys.length)),
          );
        }
      } finally {
        client.close();
      }
      for (final o in selected) {
        await ref
            .read(favoritesProvider.notifier)
            .remove(
              FavoritesStore.idFor(widget.accountId, widget.bucket, o.key),
            );
      }
      _exitSelection();
      _refresh();
      _snack('${selected.length} object(s) deleted');
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  Future<void> _downloadSelected() async {
    final selected = _selectedObjects;
    if (selected.isEmpty) return;
    final manager = ref.read(transferManagerProvider.notifier);
    for (final o in selected) {
      await manager.enqueueDownload(
        accountId: widget.accountId,
        bucket: widget.bucket,
        key: o.key,
      );
    }
    _exitSelection();
    _snack('${selected.length} download(s) queued');
  }

  Future<void> _starSelected() async {
    final selected = _selectedObjects;
    if (selected.isEmpty) return;
    final account = ref.read(accountByIdProvider(widget.accountId));
    final favorites = ref.read(favoritesProvider.notifier);
    var added = 0;
    for (final o in selected) {
      final id = FavoritesStore.idFor(widget.accountId, widget.bucket, o.key);
      if (favorites.contains(id)) continue;
      await favorites.toggle(
        accountId: widget.accountId,
        accountName: account?.name ?? '',
        bucket: widget.bucket,
        key: o.key,
        name: o.name,
        size: o.size,
      );
      added++;
    }
    _exitSelection();
    _snack(added == 0 ? 'Already starred' : '$added object(s) starred');
  }

  Future<void> _toggleStar(S3Object obj) async {
    final account = ref.read(accountByIdProvider(widget.accountId));
    final added = await ref
        .read(favoritesProvider.notifier)
        .toggle(
          accountId: widget.accountId,
          accountName: account?.name ?? '',
          bucket: widget.bucket,
          key: obj.key,
          name: obj.name,
          size: obj.size,
        );
    _snack(added ? 'Added "${obj.name}" to starred' : 'Removed from starred');
  }

  Future<void> _openDetails(S3Object obj) async {
    final changed = await context.push<bool>(
      Uri(
        path: '/s3/object',
        queryParameters: {
          'accountId': widget.accountId,
          'bucket': widget.bucket,
          'key': obj.key,
        },
      ).toString(),
    );
    if (changed == true && mounted) _refresh();
  }

  Future<void> _openVersions(S3Object obj) async {
    await context.push(
      Uri(
        path: '/s3/versions',
        queryParameters: {
          'accountId': widget.accountId,
          'bucket': widget.bucket,
          'key': obj.key,
        },
      ).toString(),
    );
    // Restoring/deleting a version can change the live object.
    if (mounted) _refresh();
  }

  Future<int> _enqueueUploads(Iterable<String> localPaths) async {
    final manager = ref.read(transferManagerProvider.notifier);
    var queued = 0;
    for (final path in localPaths) {
      await manager.enqueueUpload(
        accountId: widget.accountId,
        bucket: widget.bucket,
        prefix: _prefix,
        localPath: path,
      );
      queued++;
    }
    return queued;
  }

  Future<void> _upload() async {
    // file_picker v12: static API returns nullable List<PlatformFile>.
    final dynamic picked = await FilePicker.pickFiles();
    if (picked == null) return;
    final List files = picked is List ? picked : (picked.files as List);
    if (files.isEmpty) return;
    setState(() => _uploading = true);
    try {
      final paths = files
          .map((f) => (f as dynamic).path as String?)
          .whereType<String>();
      final queued = await _enqueueUploads(paths);
      _snack('$queued upload(s) queued — see Downloads');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _uploadFromLibrary() async {
    setState(() => _uploading = true);
    try {
      final files = await ImagePicker().pickMultiImage();
      if (files.isEmpty) return;
      final queued = await _enqueueUploads(files.map((f) => f.path));
      _snack('$queued upload(s) queued — see Downloads');
    } catch (e) {
      _snack('Photo picker failed: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _uploadFromCamera() async {
    try {
      final shot = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 92,
      );
      if (shot == null) return;
      setState(() => _uploading = true);
      final queued = await _enqueueUploads([shot.path]);
      _snack('$queued upload(s) queued — see Downloads');
    } catch (e) {
      _snack('Camera unavailable: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// Ask for a target file name, then share a presigned PUT URL that anyone
  /// can use to upload into the current folder until it expires.
  Future<void> _createUploadLink() async {
    final controller = TextEditingController(
      text: 'upload-${DateTime.now().millisecondsSinceEpoch}.bin',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Create upload link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Anyone with the link can upload one file to this folder until '
              'the link expires. Choose the target file name.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'File name',
                helperText: 'Saved into the current folder',
              ),
            ),
          ],
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
    controller.dispose();
    if (name == null || name.isEmpty) return;
    final account = ref.read(accountByIdProvider(widget.accountId));
    if (account == null) return;
    final key = '$_prefix$name'.replaceAll(RegExp(r'^/+'), '');
    final expiry = ref.read(linkExpiryProvider);
    final client = S3Client(account);
    try {
      final uri = client.presignedPut(
        widget.bucket,
        key,
        expiresSeconds: expiry,
      );
      await SharePlus.instance.share(
        ShareParams(
          text: uri.toString(),
          subject: 'Upload link for $key — valid ${describeExpiry(expiry)}',
        ),
      );
    } finally {
      client.close();
    }
  }

  Future<void> _showUploadSheet() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file_rounded),
              title: const Text('Upload files'),
              subtitle: const Text('Choose from device storage'),
              onTap: () => Navigator.pop(c, 'files'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Upload photos & videos'),
              onTap: () => Navigator.pop(c, 'media'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(c, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded),
              title: Text(
                'Create upload link (${describeExpiry(ref.read(linkExpiryProvider))})',
              ),
              subtitle: const Text('Let others upload to this folder'),
              onTap: () => Navigator.pop(c, 'link'),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder'),
              onTap: () => Navigator.pop(c, 'folder'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'files':
        await _upload();
      case 'media':
        await _uploadFromLibrary();
      case 'camera':
        await _uploadFromCamera();
      case 'link':
        await _createUploadLink();
      case 'folder':
        await _newFolder();
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
    final expiry = ref.read(linkExpiryProvider);
    final client = S3Client(account);
    try {
      final url = client.presignedGet(
        widget.bucket,
        obj.key,
        expiresSeconds: expiry,
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
      await ref
          .read(favoritesProvider.notifier)
          .remove(
            FavoritesStore.idFor(widget.accountId, widget.bucket, obj.key),
          );
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
      // The old key no longer exists; drop any favorite pointing at it.
      await ref
          .read(favoritesProvider.notifier)
          .remove(
            FavoritesStore.idFor(widget.accountId, widget.bucket, obj.key),
          );
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
    // Record for Home → Recently opened (fire and forget).
    final account = ref.read(accountByIdProvider(widget.accountId));
    if (account != null) {
      unawaited(
        ref
            .read(recentFilesProvider.notifier)
            .record(
              accountId: widget.accountId,
              accountName: account.name,
              bucket: widget.bucket,
              key: obj.key,
              name: obj.name,
              size: obj.size,
            ),
      );
    }
    final route = viewerRouteForKey(obj.key);
    if (route == null) {
      _showObjectSheet(obj);
      return;
    }
    final changed = await context.push<bool>(
      viewerLocation(
        route: route,
        accountId: widget.accountId,
        bucket: widget.bucket,
        key: obj.key,
      ),
    );
    // Text editor pops true after save → refresh the listing.
    if (changed == true && mounted) _refresh();
  }

  void _showObjectSheet(S3Object obj) {
    final date = obj.lastModified == null
        ? '—'
        : DateFormat.yMMMd().add_jm().format(obj.lastModified!.toLocal());
    final expiryLabel = describeExpiry(ref.read(linkExpiryProvider));
    final favoriteId = FavoritesStore.idFor(
      widget.accountId,
      widget.bucket,
      obj.key,
    );
    final starred = ref.read(favoritesProvider).any((f) => f.id == favoriteId);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
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
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('Details & tags'),
                onTap: () {
                  Navigator.pop(c);
                  _openDetails(obj);
                },
              ),
              ListTile(
                leading: const Icon(Icons.history_rounded),
                title: const Text('Version history'),
                onTap: () {
                  Navigator.pop(c);
                  _openVersions(obj);
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
                title: Text('Share link ($expiryLabel)'),
                onTap: () {
                  Navigator.pop(c);
                  _shareLink(obj);
                },
              ),
              ListTile(
                leading: Icon(
                  starred ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: starred ? const Color(0xFFFBBF24) : null,
                ),
                title: Text(starred ? 'Remove from starred' : 'Add to starred'),
                onTap: () {
                  Navigator.pop(c);
                  _toggleStar(obj);
                },
              ),
              ListTile(
                leading: const Icon(Icons.checklist_rounded),
                title: const Text('Select'),
                onTap: () {
                  Navigator.pop(c);
                  _enterSelection(obj);
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
      ),
    );
  }

  PreferredSizeWidget _selectionAppBar() {
    final allSelected =
        _visibleObjects.isNotEmpty &&
        _selectedKeys.length == _visibleObjects.length;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close_rounded),
        tooltip: 'Exit selection',
        onPressed: _exitSelection,
      ),
      title: Text(
        '${_selectedKeys.length} selected',
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      actions: [
        TextButton(
          onPressed: _visibleObjects.isEmpty ? null : _selectAll,
          child: Text(allSelected ? 'None' : 'All'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final viewMode = ref.watch(viewModeProvider);
    final isGrid = viewMode == ViewMode.grid;
    final favoriteIds = ref.watch(
      favoritesProvider.select((list) => {for (final f in list) f.id}),
    );
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
      appBar: _selectionMode
          ? _selectionAppBar()
          : AppBar(
              title: Text(
                widget.bucket,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.checklist_rounded),
                  tooltip: 'Select objects',
                  onPressed: () => _enterSelection(),
                ),
                IconButton(
                  icon: Icon(
                    isGrid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                  ),
                  tooltip: isGrid ? 'List view' : 'Grid view',
                  onPressed: () => ref.read(viewModeProvider.notifier).toggle(),
                ),
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
                    onPressed: _uploading ? null : _showUploadSheet,
                  ),
                );
              }
              // Keep the current page for Select all (filtered view).
              _visibleObjects = objects;
              return RefreshIndicator(
                onRefresh: () async => _refresh(),
                child: isGrid
                    ? GridView.builder(
                        padding: const EdgeInsets.fromLTRB(
                          16,
                          8,
                          16,
                          kFloatingNavBarClearance,
                        ),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 0.86,
                            ),
                        itemCount:
                            prefixes.length +
                            objects.length +
                            (result.isTruncated ? 1 : 0),
                        itemBuilder: (c, i) {
                          if (i < prefixes.length) {
                            final p = prefixes[i];
                            return _FolderGridTile(
                              prefix: p,
                              prefixBase: _prefix,
                              onTap: () => _enterPrefix(p),
                            );
                          }
                          final oi = i - prefixes.length;
                          if (oi < objects.length) {
                            final obj = objects[oi];
                            return _ObjectGridTile(
                              obj: obj,
                              scheme: scheme,
                              selected: _selectedKeys.contains(obj.key),
                              selectionMode: _selectionMode,
                              starred: favoriteIds.contains(
                                FavoritesStore.idFor(
                                  widget.accountId,
                                  widget.bucket,
                                  obj.key,
                                ),
                              ),
                              onTap: () => _selectionMode
                                  ? _toggleSelected(obj)
                                  : _openObject(obj),
                              onLongPress: () => _selectionMode
                                  ? _toggleSelected(obj)
                                  : _showObjectSheet(obj),
                            );
                          }
                          return Center(
                            child: _loadingMore
                                ? const CircularProgressIndicator()
                                : OutlinedButton.icon(
                                    onPressed: () => _loadMore(result),
                                    icon: const Icon(Icons.expand_more_rounded),
                                    label: const Text('More'),
                                  ),
                          );
                        },
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(
                          16,
                          8,
                          16,
                          kFloatingNavBarClearance,
                        ),
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
                              selected: _selectedKeys.contains(obj.key),
                              selectionMode: _selectionMode,
                              starred: favoriteIds.contains(
                                FavoritesStore.idFor(
                                  widget.accountId,
                                  widget.bucket,
                                  obj.key,
                                ),
                              ),
                              onTap: () => _selectionMode
                                  ? _toggleSelected(obj)
                                  : _openObject(obj),
                              onLongPress: () => _selectionMode
                                  ? _toggleSelected(obj)
                                  : _showObjectSheet(obj),
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
                                      icon: const Icon(
                                        Icons.expand_more_rounded,
                                      ),
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
      bottomNavigationBar: _selectionMode
          ? BottomAppBar(
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.download_rounded),
                    tooltip: 'Download selected',
                    onPressed: _selectedKeys.isEmpty ? null : _downloadSelected,
                  ),
                  IconButton(
                    icon: const Icon(Icons.star_rounded),
                    tooltip: 'Star selected',
                    onPressed: _selectedKeys.isEmpty ? null : _starSelected,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    tooltip: 'Delete selected',
                    onPressed: _selectedKeys.isEmpty ? null : _deleteSelected,
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(
                      '${_selectedKeys.length} selected',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            )
          : null,
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _uploading ? null : _showUploadSheet,
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
  final VoidCallback? onLongPress;
  final bool selected;
  final bool selectionMode;
  final bool starred;
  const _ObjectCard({
    required this.obj,
    required this.scheme,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.selectionMode = false,
    this.starred = false,
  });

  Color get _tint => fileTint(obj.key, scheme.primary);

  IconData get _icon => fileIcon(obj.key);

  @override
  Widget build(BuildContext context) {
    return Glass(
      padding: const EdgeInsets.all(12),
      radius: 16,
      onTap: onTap,
      onLongPress: onLongPress,
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
                  formatBytes(obj.size),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          if (starred && !selectionMode)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(
                Icons.star_rounded,
                size: 16,
                color: Color(0xFFFBBF24),
              ),
            ),
          if (selectionMode)
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked,
              size: 22,
              color: selected
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.4),
            )
          else if (viewerKindForKey(obj.key) != null)
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

/// Grid tile for folders (default view).
class _FolderGridTile extends StatelessWidget {
  final String prefix;
  final String prefixBase;
  final VoidCallback onTap;
  const _FolderGridTile({
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
      padding: const EdgeInsets.all(14),
      radius: 18,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 48,
            width: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              gradient: const LinearGradient(
                colors: [Color(0xFF38BDF8), AppColors.indigo],
              ),
            ),
            child: const Icon(
              Icons.folder_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
          const Spacer(),
          Text(
            name.isEmpty ? prefix : name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 2),
          Text(
            'Folder',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

/// Grid tile for files (default view). Long-press opens the action sheet.
class _ObjectGridTile extends StatelessWidget {
  final S3Object obj;
  final ColorScheme scheme;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool selectionMode;
  final bool starred;
  const _ObjectGridTile({
    required this.obj,
    required this.scheme,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.selectionMode = false,
    this.starred = false,
  });

  Color get _tint => fileTint(obj.key, scheme.primary);

  IconData get _icon => fileIcon(obj.key);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Glass(
          padding: const EdgeInsets.all(14),
          radius: 18,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 48,
                width: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  color: _tint.withValues(alpha: 0.18),
                  border: Border.all(color: _tint.withValues(alpha: 0.35)),
                ),
                child: Icon(_icon, color: _tint, size: 26),
              ),
              const Spacer(),
              Text(
                obj.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                formatBytes(obj.size),
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
        if (selectionMode)
          Positioned(
            top: 10,
            right: 10,
            child: Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked,
              size: 22,
              color: selected
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.45),
            ),
          )
        else if (starred)
          const Positioned(
            top: 10,
            right: 10,
            child: Icon(Icons.star_rounded, size: 18, color: Color(0xFFFBBF24)),
          ),
      ],
    );
  }
}
