// Starred files (favorites) shown on Home. Persisted in SharedPreferences
// (metadata only — no keys), capped, most-recent first.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kFavorites = 'clouddock.favorites.v1';
const _kMaxFavorites = 200;

class FavoriteFile {
  final String accountId;
  final String accountName;
  final String bucket;
  final String key;
  final String name;
  final int size;
  final DateTime addedAt;

  const FavoriteFile({
    required this.accountId,
    required this.accountName,
    required this.bucket,
    required this.key,
    required this.name,
    required this.size,
    required this.addedAt,
  });

  String get id => '$accountId::$bucket::$key';

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'accountName': accountName,
    'bucket': bucket,
    'key': key,
    'name': name,
    'size': size,
    'addedAt': addedAt.toIso8601String(),
  };

  static FavoriteFile? fromJson(Map<String, dynamic> json) {
    try {
      return FavoriteFile(
        accountId: json['accountId'] as String? ?? '',
        accountName: json['accountName'] as String? ?? '',
        bucket: json['bucket'] as String? ?? '',
        key: json['key'] as String? ?? '',
        name: json['name'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        addedAt:
            DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}

class FavoritesStore extends StateNotifier<List<FavoriteFile>> {
  FavoritesStore() : super(const []) {
    _load();
  }

  static String idFor(String accountId, String bucket, String key) =>
      '$accountId::$bucket::$key';

  bool contains(String id) => state.any((f) => f.id == id);

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kFavorites);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final items = decoded
          .whereType<Map>()
          .map((e) => FavoriteFile.fromJson(Map<String, dynamic>.from(e)))
          .whereType<FavoriteFile>()
          .toList();
      items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      state = items.take(_kMaxFavorites).toList();
    } catch (_) {
      // Keep empty on corrupt data.
    }
  }

  Future<void> _persist(List<FavoriteFile> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kFavorites,
        jsonEncode(items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  /// Star/unstar; returns true when the file is now a favorite.
  Future<bool> toggle({
    required String accountId,
    required String accountName,
    required String bucket,
    required String key,
    required String name,
    required int size,
  }) async {
    final id = idFor(accountId, bucket, key);
    if (contains(id)) {
      await remove(id);
      return false;
    }
    final entry = FavoriteFile(
      accountId: accountId,
      accountName: accountName,
      bucket: bucket,
      key: key,
      name: name,
      size: size,
      addedAt: DateTime.now(),
    );
    final next = [entry, ...state].take(_kMaxFavorites).toList();
    state = next;
    await _persist(next);
    return true;
  }

  Future<void> remove(String id) async {
    final next = state.where((f) => f.id != id).toList();
    state = next;
    await _persist(next);
  }

  /// Drop entries whose account no longer exists.
  void prune(Set<String> liveAccountIds) {
    final next = state
        .where((f) => liveAccountIds.contains(f.accountId))
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

final favoritesProvider =
    StateNotifierProvider<FavoritesStore, List<FavoriteFile>>(
      (ref) => FavoritesStore(),
    );
