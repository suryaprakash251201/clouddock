// Video player: streams via presigned URL (no full download) with
// Chewie controls (play/pause, seek, fullscreen).

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/s3/s3_client.dart';
import '../../core/storage/account_store.dart';
import '../transfers/transfer_manager.dart';

class VideoPlayerScreen extends ConsumerStatefulWidget {
  final String accountId;
  final String bucket;
  final String objectKey;
  const VideoPlayerScreen({
    super.key,
    required this.accountId,
    required this.bucket,
    required this.objectKey,
  });

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends ConsumerState<VideoPlayerScreen> {
  VideoPlayerController? _video;
  ChewieController? _chewie;
  Object? _error;
  bool _starting = true;

  String get _name => widget.objectKey.split('/').last;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _video?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final account = ref.read(accountByIdProvider(widget.accountId));
      if (account == null) throw StateError('Account not found');
      final client = S3Client(account);
      // Pure signing (no network); long expiry for the streaming session.
      final url = client.presignedGet(
        widget.bucket,
        widget.objectKey,
        expiresSeconds: 21600,
      );
      client.close();

      final video = VideoPlayerController.networkUrl(Uri.parse(url.toString()));
      await video.initialize();
      final chewie = ChewieController(
        videoPlayerController: video,
        autoPlay: true,
        allowFullScreen: true,
        allowMuting: true,
        showControlsOnInitialize: false,
      );
      if (!mounted) {
        chewie.dispose();
        video.dispose();
        return;
      }
      setState(() {
        _video = video;
        _chewie = chewie;
        _starting = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _starting = false;
        });
      }
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
      body: Center(
        child: _starting
            ? const CircularProgressIndicator()
            : _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.white70,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _start, child: const Text('Retry')),
                  ],
                ),
              )
            : Chewie(controller: _chewie!),
      ),
    );
  }
}
