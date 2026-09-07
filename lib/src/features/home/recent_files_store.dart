// Recently opened files for the Home tab. Persisted in SharedPreferences
// (metadata only — no keys), capped at 20 entries, most-recent first.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kRecents = 'clouddock.recents.v1';
const _kMaxRecents = 20;

class RecentFile {
  final String accountId;
  final String accountName;
  final String bucket;
  final String key;
  final String name;
  final int size;
  final DateTime openedAt;

  const RecentFile({
    required this.accountId,
    required this.accountName,
    required this.bucket,
    required this.key,
    required this.name,
    required this.size,
    required this.openedAt,
  });

  String get id => '$accountId::$bucket::$key';

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'accountName': accountName,
    'bucket': bucket,
    'key': key,
    'name': name,
    'size': size,
    'openedAt': openedAt.toIso8601String(),
  };

  static RecentFile? fromJson(Map<String, dynamic> json) {
    try {
      return RecentFile(
        accountId: json['accountId'] as String? ?? '',
        accountName: json['accountName'] as String? ?? '',
        bucket: json['bucket'] as String? ?? '',
        key: json['key'] as String? ?? '',
        name: json['name'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        openedAt:
            DateTime.tryParse(json['openedAt'] as String? ?? '') ??
            DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}

class RecentFilesStore extends StateNotifier<List<RecentFile>> {
  RecentFilesStore() : super(const []) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kRecents);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final items = decoded
          .whereType<Map>()
          .map((e) => RecentFile.fromJson(Map<String, dynamic>.from(e)))
          .whereType<RecentFile>()
          .toList();
      items.sort((a, b) => b.openedAt.compareTo(a.openedAt));
      state = items.take(_kMaxRecents).toList();
    } catch (_) {
      // Keep empty on corrupt data.
    }
  }

  Future<void> _persist(List<RecentFile> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kRecents,
        jsonEncode(items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> record({
    required String accountId,
    required String accountName,
    required String bucket,
    required String key,
    required String name,
    required int size,
  }) async {
    final entry = RecentFile(
      accountId: accountId,
      accountName: accountName,
      bucket: bucket,
      key: key,
      name: name,
      size: size,
      openedAt: DateTime.now(),
    );
    final next = [
      entry,
      for (final r in state)
        if (r.id != entry.id) r,
    ].take(_kMaxRecents).toList();
    state = next;
    await _persist(next);
  }

  Future<void> remove(String id) async {
    final next = state.where((r) => r.id != id).toList();
    state = next;
    await _persist(next);
  }

  /// Drop entries whose account no longer exists.
  void prune(Set<String> liveAccountIds) {
    final next = state
        .where((r) => liveAccountIds.contains(r.accountId))
        .toList();
    if (next.length != state.length) {
      state = next;
      _persist(next);
    }
  }

  Future<void> clear() async {
    state = const [];
    await _persist(const []);
  }
}

final recentFilesProvider =
    StateNotifierProvider<RecentFilesStore, List<RecentFile>>(
      (ref) => RecentFilesStore(),
    );
