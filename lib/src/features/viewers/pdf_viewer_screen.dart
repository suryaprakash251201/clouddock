// PDF viewer (pdfrx/PDFium): downloads the object to a temp file.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/s3/s3_client.dart';
import '../../core/storage/account_store.dart';
import '../transfers/transfer_manager.dart';

class PdfViewerScreen extends ConsumerStatefulWidget {
  final String accountId;
  final String bucket;
  final String objectKey;
  const PdfViewerScreen({
    super.key,
    required this.accountId,
    required this.bucket,
    required this.objectKey,
  });

  @override
  ConsumerState<PdfViewerScreen> createState() => _PdfViewerState();
}

class _PdfViewerState extends ConsumerState<PdfViewerScreen> {
  late final Future<String> _future = _downloadToTemp();

  String get _name => widget.objectKey.split('/').last;

  Future<String> _downloadToTemp() async {
    final account = ref.read(accountByIdProvider(widget.accountId));
    if (account == null) throw StateError('Account not found');
    final dir = await getTemporaryDirectory();
    final savePath = p.join(
      dir.path,
      'CloudDock-preview',
      widget.bucket,
      widget.objectKey.replaceAll('/', '_'),
    );
    final client = S3Client(account);
    try {
      final file = await client.downloadToFile(
        widget.bucket,
        widget.objectKey,
        savePath,
      );
      return file.path;
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
      body: FutureBuilder<String>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${snap.error}', textAlign: TextAlign.center),
              ),
            );
          }
          // Text selection + outline enabled by default in pdfrx.
          return PdfViewer.file(snap.data!);
        },
      ),
    );
  }
}
