// Full-screen image viewer with pinch-to-zoom (downloads bytes via S3).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/s3/s3_client.dart';
import '../../core/storage/account_store.dart';
import '../transfers/transfer_manager.dart';

class ImageViewerScreen extends ConsumerStatefulWidget {
  final String accountId;
  final String bucket;
  final String objectKey;
  const ImageViewerScreen({
    super.key,
    required this.accountId,
    required this.bucket,
    required this.objectKey,
  });

  @override
  ConsumerState<ImageViewerScreen> createState() => _ImageViewerState();
}

class _ImageViewerState extends ConsumerState<ImageViewerScreen> {
  late Future<Uint8List> _future;

  static const _maxInlineBytes = 25 * 1024 * 1024; // 25 MB

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  void _retry() {
    if (!mounted) return;
    setState(() => _future = _load());
  }

  String get _name => widget.objectKey.split('/').last;

  Future<Uint8List> _load() async {
    final account = ref.read(accountByIdProvider(widget.accountId));
    if (account == null) throw StateError('Account not found');
    final client = S3Client(account);
    try {
      // HEAD first so huge images don't OOM the viewer.
      final meta = await client.headObject(widget.bucket, widget.objectKey);
      if (meta != null && meta.size > _maxInlineBytes) {
        throw StateError(
          'Image is ${(meta.size / 1048576).toStringAsFixed(1)} MB — '
          'too large to preview. Use Download instead.',
        );
      }
      final resp = await client.getObject(widget.bucket, widget.objectKey);
      final total = resp.contentLength;
      if (total != null && total > _maxInlineBytes) {
        await resp.stream.drain();
        throw StateError(
          'Image is ${(total / 1048576).toStringAsFixed(1)} MB — '
          'too large to preview. Use Download instead.',
        );
      }
      final bytes = await resp.stream.toBytes();
      if (bytes.length > _maxInlineBytes) {
        throw StateError(
          'Image is ${(bytes.length / 1048576).toStringAsFixed(1)} MB — '
          'too large to preview. Use Download instead.',
        );
      }
      return bytes;
    } finally {
      client.close();
    }
  }

  Future<void> _download() async {
    await ref
        .read(transferManagerProvider.notifier)
        .enqueueDownload(
          accountId: widget.accountId,
          bucket: widget.bucket,
          key: widget.objectKey,
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Downloading — see Transfers')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Download',
            onPressed: _download,
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: FutureBuilder<Uint8List>(
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
                    const Icon(
                      Icons.broken_image_outlined,
                      size: 48,
                      color: Colors.white70,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${snap.error}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _retry, child: const Text('Retry')),
                  ],
                ),
              ),
            );
          }
          return Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Image.memory(snap.data!, fit: BoxFit.contain),
            ),
          );
        },
      ),
    );
  }
}
