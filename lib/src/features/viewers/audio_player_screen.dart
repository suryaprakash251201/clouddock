// Inbuilt music player: streams audio via presigned URL (no full download)
// with just_audio (ExoPlayer on Android / AVPlayer on iOS).
//
// Supported: mp3, m4a, aac, wav, ogg/oga, opus, flac + OS-dependent extras
// (aiff, amr, midi, wma, mka...). If the OS decoder rejects a format, the
// error view offers Download + open-externally fallback.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/s3/s3_client.dart';
import '../../core/storage/account_store.dart';
import '../transfers/transfer_manager.dart';
import 'viewer_kind.dart';

class AudioPlayerScreen extends ConsumerStatefulWidget {
  final String accountId;
  final String bucket;
  final String objectKey;
  const AudioPlayerScreen({
    super.key,
    required this.accountId,
    required this.bucket,
    required this.objectKey,
  });

  @override
  ConsumerState<AudioPlayerScreen> createState() => _AudioPlayerState();
}

class _AudioPlayerState extends ConsumerState<AudioPlayerScreen> {
  late final AudioPlayer _player;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;

  Object? _error;
  bool _starting = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _seeking = false;
  double _seekValue = 0;
  double _speed = 1.0;

  String get _name => widget.objectKey.split('/').last;
  String get _ext => extensionOfKey(widget.objectKey).toUpperCase();

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _posSub = _player.positionStream.listen((p) {
      if (mounted && !_seeking) {
        setState(() {
          _position = p;
          _seekValue = _duration.inMilliseconds > 0
              ? p.inMilliseconds.clamp(0, _duration.inMilliseconds).toDouble()
              : 0;
        });
      }
    });
    _durSub = _player.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _duration = d);
    });
    _stateSub = _player.playerStateStream.listen((s) {
      if (!mounted) return;
      setState(() {
        _playing = s.playing;
        if (s.processingState == ProcessingState.completed) {
          _position = _duration;
          _seekValue = _duration.inMilliseconds.toDouble();
        }
      });
    });
    _start(autoplay: true);
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _start({bool autoplay = true}) async {
    if (mounted) {
      setState(() {
        _starting = true;
        _error = null;
        _position = Duration.zero;
        _seekValue = 0;
      });
    }
    try {
      final account = ref.read(accountByIdProvider(widget.accountId));
      if (account == null) throw StateError('Account not found');
      final client = S3Client(account);
      // Pure signing (no network); regenerated every start so retries
      // never reuse an expired URL.
      final url = client.presignedGet(
        widget.bucket,
        widget.objectKey,
        expiresSeconds: 21600,
      );
      client.close();

      await _player.stop();
      await _player.setUrl(url.toString()).timeout(const Duration(seconds: 30));
      await _player.setSpeed(_speed);
      if (!mounted) return;
      setState(() => _starting = false);
      if (autoplay) await _player.play();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _starting = false;
        });
      }
    }
  }

  Future<void> _toggle() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      // Replay from start when completed.
      if (_duration > Duration.zero && _position >= _duration) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
  }

  Future<void> _seekRelative(int seconds) async {
    final target = _position + Duration(seconds: seconds);
    final clamped = target.isNegative
        ? Duration.zero
        : (target > _duration && _duration > Duration.zero
              ? _duration
              : target);
    await _player.seek(clamped);
  }

  Future<void> _cycleSpeed() async {
    const speeds = [1.0, 1.25, 1.5, 2.0, 0.75];
    final next = speeds[(speeds.indexOf(_speed) + 1) % speeds.length];
    await _player.setSpeed(next);
    if (mounted) setState(() => _speed = next);
  }

  Future<void> _download({bool openAfter = false}) async {
    final id = await ref
        .read(transferManagerProvider.notifier)
        .enqueueDownload(
          accountId: widget.accountId,
          bucket: widget.bucket,
          key: widget.objectKey,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          openAfter
              ? 'Downloading for external player…'
              : 'Downloading — see Transfers',
        ),
        action: openAfter
            ? SnackBarAction(
                label: 'Open',
                onPressed: () async {
                  for (var i = 0; i < 60; i++) {
                    await Future.delayed(const Duration(seconds: 1));
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
              )
            : null,
      ),
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxMs = _duration.inMilliseconds.toDouble();
    return Scaffold(
      appBar: AppBar(
        title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Download',
            onPressed: () => _download(),
          ),
        ],
      ),
      body: Center(
        child: _starting
            ? const CircularProgressIndicator()
            : _error != null
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.music_off_outlined, size: 48),
                    const SizedBox(height: 12),
                    Text(
                      'Could not play this audio.\n$_error',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'If the format is unsupported on this device, '
                      'download it and open with an external player.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        FilledButton(
                          onPressed: () => _start(),
                          child: const Text('Retry'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _download(openAfter: true),
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('Download'),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 160,
                      width: 160,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(32),
                        gradient: LinearGradient(
                          colors: [scheme.primary, scheme.secondary],
                        ),
                      ),
                      child: const Icon(
                        Icons.music_note_rounded,
                        size: 80,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${_ext.isEmpty ? 'AUDIO' : _ext} • ${widget.bucket}',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Slider(
                      value: maxMs <= 0 ? 0 : _seekValue.clamp(0, maxMs),
                      max: maxMs <= 0 ? 1 : maxMs,
                      onChangeStart: (_) => _seeking = true,
                      onChanged: (v) => setState(() => _seekValue = v),
                      onChangeEnd: (v) async {
                        _seeking = false;
                        await _player.seek(Duration(milliseconds: v.toInt()));
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_fmt(_position)),
                          Text(_fmt(_duration)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          iconSize: 32,
                          tooltip: 'Back 10s',
                          icon: const Icon(Icons.replay_10_rounded),
                          onPressed: () => _seekRelative(-10),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: const EdgeInsets.all(20),
                          ),
                          onPressed: _toggle,
                          child: Icon(
                            _playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 36,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          iconSize: 32,
                          tooltip: 'Forward 10s',
                          icon: const Icon(Icons.forward_10_rounded),
                          onPressed: () => _seekRelative(10),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        OutlinedButton(
                          onPressed: _cycleSpeed,
                          child: Text('${_speed}x speed'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _start(autoplay: true),
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Restart'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
