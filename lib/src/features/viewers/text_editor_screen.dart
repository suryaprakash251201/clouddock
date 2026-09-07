// In-app text editor: loads UTF-8 objects, edits, saves back to S3.
// Files over [_editLimit] bytes open read-only.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';

import '../../core/s3/s3_client.dart';
import '../../core/storage/account_store.dart';

const _editLimit = 2 * 1024 * 1024; // 2 MB
const _viewLimit = 10 * 1024 * 1024; // 10 MB view cap

class TextEditorScreen extends ConsumerStatefulWidget {
  final String accountId;
  final String bucket;
  final String objectKey;
  const TextEditorScreen({
    super.key,
    required this.accountId,
    required this.bucket,
    required this.objectKey,
  });

  @override
  ConsumerState<TextEditorScreen> createState() => _TextEditorState();
}

class _TextEditorState extends ConsumerState<TextEditorScreen> {
  late final Future<({String text, bool readOnly})> _future = _load();
  final _controller = TextEditingController();
  bool _dirty = false;
  bool _saving = false;
  bool _loaded = false;

  String get _name => widget.objectKey.split('/').last;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<({String text, bool readOnly})> _load() async {
    final account = ref.read(accountByIdProvider(widget.accountId));
    if (account == null) throw StateError('Account not found');
    final client = S3Client(account);
    try {
      // HEAD first to avoid downloading huge files into memory.
      final meta = await client.headObject(widget.bucket, widget.objectKey);
      if (meta != null && meta.size > _viewLimit) {
        throw StateError(
          'File is ${(meta.size / 1048576).toStringAsFixed(1)} MB — '
          'too large to view in-app. Use Download instead.',
        );
      }
      final resp = await client.getObject(widget.bucket, widget.objectKey);
      final bytes = await resp.stream.toBytes();
      if (bytes.length > _viewLimit) {
        throw StateError(
          'File is ${(bytes.length / 1048576).toStringAsFixed(1)} MB — '
          'too large to view in-app. Use Download instead.',
        );
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      return (text: text, readOnly: bytes.length > _editLimit);
    } finally {
      client.close();
    }
  }

  void _onLoaded(String text, bool readOnly) {
    if (_loaded) return;
    _loaded = true;
    _controller.text = text;
    if (!readOnly) {
      _controller.addListener(() {
        final dirty = _controller.text != text;
        if (dirty != _dirty && mounted) setState(() => _dirty = dirty);
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final account = ref.read(accountByIdProvider(widget.accountId))!;
      final client = S3Client(account);
      try {
        await client.putObject(
          widget.bucket,
          widget.objectKey,
          utf8.encode(_controller.text),
          contentType:
              lookupMimeType(widget.objectKey) ?? 'text/plain; charset=utf-8',
        );
      } finally {
        client.close();
      }
      if (!mounted) return;
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('You have unsaved edits.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          Navigator.of(context).pop(false);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (_dirty && !_saving)
              TextButton(onPressed: _save, child: const Text('Save')),
            if (_saving)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
        body: FutureBuilder<({String text, bool readOnly})>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(child: Text('${snap.error}'));
            }
            final data = snap.data!;
            _onLoaded(data.text, data.readOnly);
            return Column(
              children: [
                if (data.readOnly)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      'File is too large to edit — opened read-only.',
                      style: TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: TextField(
                      controller: _controller,
                      readOnly: data.readOnly,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      keyboardType: TextInputType.multiline,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        height: 1.4,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.all(12),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        floatingActionButton: _dirty && !_saving
            ? FloatingActionButton.extended(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save'),
              )
            : null,
      ),
    );
  }
}
