// Foreground transfer manager: single-PUT for small files, multipart for
// large ones, streaming downloads with progress. State persists in memory
// for the session (survives navigation, not process death — V2 moves to
// WorkManager/BGTasks via background_downloader).

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/s3/s3_client.dart';
import '../../core/s3/s3_models.dart';
import '../../core/storage/account_store.dart';

enum TransferType { upload, download }

enum TransferStatus { queued, running, done, failed, canceled }

class TransferTask {
  final String id;
  final TransferType type;
  final String accountId;
  final String bucket;
  final String key;
  final String localPath;
  final TransferStatus status;
  final double progress; // 0..1
  final String? error;
  final int? totalBytes;

  const TransferTask({
    required this.id,
    required this.type,
    required this.accountId,
    required this.bucket,
    required this.key,
    required this.localPath,
    this.status = TransferStatus.queued,
    this.progress = 0,
    this.error,
    this.totalBytes,
  });

  TransferTask copyWith({
    TransferStatus? status,
    double? progress,
    String? error,
    bool clearError = false,
    int? totalBytes,
  }) => TransferTask(
    id: id,
    type: type,
    accountId: accountId,
    bucket: bucket,
    key: key,
    localPath: localPath,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    error: clearError ? null : (error ?? this.error),
    totalBytes: totalBytes ?? this.totalBytes,
  );
}

const _multipartThreshold = 8 * 1024 * 1024; // 8 MB
const _multipartPartSize = 8 * 1024 * 1024;
const _maxConcurrent = 3;
const _uuid = Uuid();

class TransferManager extends StateNotifier<List<TransferTask>> {
  final Ref _ref;
  final Map<String, bool> _cancelFlags = {};
  final Map<String, S3Client> _clients = {};
  int _running = 0;

  TransferManager(this._ref) : super(const []);

  List<TransferTask> get active => state
      .where(
        (t) =>
            t.status == TransferStatus.running ||
            t.status == TransferStatus.queued,
      )
      .toList();

  void _update(String id, TransferTask Function(TransferTask) fn) {
    state = [
      for (final t in state)
        if (t.id == id) fn(t) else t,
    ];
  }

  void cancel(String id) {
    _cancelFlags[id] = true;
    // Closing the per-task client aborts the in-flight HTTP request.
    try {
      _clients[id]?.close();
    } catch (_) {
      // best effort
    }
    _update(id, (t) => t.copyWith(status: TransferStatus.canceled));
  }

  /// Remove a single task. Optionally delete its local file.
  Future<void> remove(String id, {bool deleteLocalFile = false}) async {
    TransferTask? task;
    try {
      task = state.firstWhere((t) => t.id == id);
    } catch (_) {
      return;
    }
    if (task.status == TransferStatus.running ||
        task.status == TransferStatus.queued) {
      cancel(id);
    }
    if (deleteLocalFile) {
      try {
        final file = File(task.localPath);
        if (await file.exists()) await file.delete();
        final part = File('${task.localPath}.part');
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
    _cancelFlags.remove(id);
    _clients.remove(id);
    state = state.where((t) => t.id != id).toList();
  }

  /// Clear done + canceled, keep queued/running/failed for retry.
  void clearFinished() {
    state = state
        .where(
          (t) =>
              t.status == TransferStatus.running ||
              t.status == TransferStatus.queued ||
              t.status == TransferStatus.failed,
        )
        .toList();
  }

  void clearFailed() {
    final ids = state
        .where((t) => t.status == TransferStatus.failed)
        .map((t) => t.id)
        .toSet();
    _cancelFlags.removeWhere((k, _) => ids.contains(k));
    state = state.where((t) => !ids.contains(t.id)).toList();
  }

  /// Re-run a single failed/canceled task.
  Future<void> retry(String id) async {
    TransferTask? task;
    try {
      task = state.firstWhere((t) => t.id == id);
    } catch (_) {
      return;
    }
    if (task.status != TransferStatus.failed &&
        task.status != TransferStatus.canceled) {
      return;
    }
    _cancelFlags.remove(id);
    _update(
      id,
      (t) => t.copyWith(
        status: TransferStatus.queued,
        progress: 0,
        clearError: true,
      ),
    );
    unawaited(
      task.type == TransferType.upload ? _runUpload(id) : _runDownload(id),
    );
  }

  Future<void> retryAllFailed() async {
    final ids = state
        .where(
          (t) =>
              t.status == TransferStatus.failed ||
              t.status == TransferStatus.canceled,
        )
        .map((t) => t.id)
        .toList();
    for (final id in ids) {
      await retry(id);
    }
  }

  Future<void> _acquireSlot(String id) async {
    while (_running >= _maxConcurrent) {
      _checkCancel(id);
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _running++;
  }

  void _releaseSlot() {
    _running = max(0, _running - 1);
  }

  S3Client _clientFor(String accountId) {
    final account = _ref.read(accountByIdProvider(accountId));
    if (account == null) throw StateError('Account not found: $accountId');
    return S3Client(account);
  }

  // ---------- uploads ----------

  Future<String> enqueueUpload({
    required String accountId,
    required String bucket,
    required String prefix,
    required String localPath,
  }) async {
    final fileName = p.basename(localPath);
    final key = '$prefix$fileName'.replaceAll(RegExp(r'^/+'), '');
    final task = TransferTask(
      id: _uuid.v4(),
      type: TransferType.upload,
      accountId: accountId,
      bucket: bucket,
      key: key,
      localPath: localPath,
    );
    state = [...state, task];
    unawaited(_runUpload(task.id));
    return task.id;
  }

  Future<void> _runUpload(String id) async {
    TransferTask task;
    try {
      task = state.firstWhere((t) => t.id == id);
    } catch (_) {
      return;
    }
    await _acquireSlot(id);
    final client = _clientFor(task.accountId);
    _clients[id] = client;
    try {
      _update(
        id,
        (t) => t.copyWith(status: TransferStatus.running, clearError: true),
      );
      final file = File(task.localPath);
      final length = await file.length();
      _update(id, (t) => t.copyWith(totalBytes: length));
      final contentType = lookupMimeType(task.localPath);

      if (length <= _multipartThreshold) {
        final bytes = await file.readAsBytes();
        _checkCancel(id);
        _update(id, (t) => t.copyWith(progress: 0.1));
        await client.putObject(
          task.bucket,
          task.key,
          bytes,
          contentType: contentType,
        );
        _checkCancel(id);
        _update(
          id,
          (t) => t.copyWith(status: TransferStatus.done, progress: 1),
        );
      } else {
        await _multipartUpload(client, task, file, length, contentType, id);
      }
    } catch (e) {
      if (_cancelFlags[id] == true) {
        _update(id, (t) => t.copyWith(status: TransferStatus.canceled));
      } else {
        _update(
          id,
          (t) => t.copyWith(status: TransferStatus.failed, error: '$e'),
        );
      }
    } finally {
      _clients.remove(id);
      try {
        client.close();
      } catch (_) {}
      _releaseSlot();
    }
  }

  Future<void> _multipartUpload(
    S3Client client,
    TransferTask task,
    File file,
    int length,
    String? contentType,
    String id,
  ) async {
    final uploadId = await client.createMultipartUpload(
      task.bucket,
      task.key,
      contentType: contentType,
    );
    try {
      final parts = <CompletedPart>[];
      final raf = await file.open();
      try {
        var partNumber = 1;
        var offset = 0;
        while (offset < length) {
          _checkCancel(id);
          final size = (offset + _multipartPartSize > length)
              ? length - offset
              : _multipartPartSize;
          await raf.setPosition(offset);
          final bytes = await raf.read(size);
          final etag = await client.uploadPart(
            task.bucket,
            task.key,
            uploadId,
            partNumber,
            Stream.value(bytes),
            bytes.length,
          );
          parts.add(CompletedPart(partNumber, etag));
          offset += size;
          partNumber++;
          final progress = offset / length;
          _update(id, (t) => t.copyWith(progress: progress));
        }
      } finally {
        await raf.close();
      }
      _checkCancel(id);
      await client.completeMultipartUpload(
        task.bucket,
        task.key,
        uploadId,
        parts,
      );
      _update(id, (t) => t.copyWith(status: TransferStatus.done, progress: 1));
    } catch (e) {
      try {
        await client.abortMultipartUpload(task.bucket, task.key, uploadId);
      } catch (_) {
        // best effort
      }
      rethrow;
    }
  }

  void _checkCancel(String id) {
    if (_cancelFlags[id] == true) throw StateError('canceled');
  }

  // ---------- downloads ----------

  Future<String> enqueueDownload({
    required String accountId,
    required String bucket,
    required String key,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final savePath = p.join(dir.path, 'CloudDock', bucket, key);
    final task = TransferTask(
      id: _uuid.v4(),
      type: TransferType.download,
      accountId: accountId,
      bucket: bucket,
      key: key,
      localPath: savePath,
    );
    state = [...state, task];
    unawaited(_runDownload(task.id));
    return task.id;
  }

  Future<void> _runDownload(String id) async {
    TransferTask task;
    try {
      task = state.firstWhere((t) => t.id == id);
    } catch (_) {
      return;
    }
    await _acquireSlot(id);
    final client = _clientFor(task.accountId);
    _clients[id] = client;
    try {
      _update(
        id,
        (t) => t.copyWith(status: TransferStatus.running, clearError: true),
      );
      _checkCancel(id);
      await client.downloadToFile(
        task.bucket,
        task.key,
        task.localPath,
        onProgress: (progress) {
          if (_cancelFlags[id] != true) {
            _update(id, (t) => t.copyWith(progress: progress));
          }
        },
      );
      if (_cancelFlags[id] == true) {
        _update(id, (t) => t.copyWith(status: TransferStatus.canceled));
        // Remove partial temp output left by cancellation.
        try {
          final tmp = File('${task.localPath}.part');
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      } else {
        _update(
          id,
          (t) => t.copyWith(status: TransferStatus.done, progress: 1),
        );
      }
    } catch (e) {
      if (_cancelFlags[id] == true) {
        _update(id, (t) => t.copyWith(status: TransferStatus.canceled));
      } else {
        _update(
          id,
          (t) => t.copyWith(status: TransferStatus.failed, error: '$e'),
        );
      }
    } finally {
      _clients.remove(id);
      try {
        client.close();
      } catch (_) {}
      _releaseSlot();
    }
  }
}

final transferManagerProvider =
    StateNotifierProvider<TransferManager, List<TransferTask>>(
      (ref) => TransferManager(ref),
    );
