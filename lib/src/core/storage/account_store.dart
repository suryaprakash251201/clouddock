// Persistent account store: metadata in SharedPreferences, secrets in
// FlutterSecureStorage. Exposed via Riverpod.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../s3/s3_account.dart';
import '../s3/s3_client.dart';

const _prefsKey = 'clouddock.accounts.v1';
const _uuid = Uuid();

class AccountStore extends StateNotifier<AsyncValue<List<S3Account>>> {
  final FlutterSecureStorage _secure;
  SharedPreferences? _prefs;

  AccountStore({FlutterSecureStorage? secure})
    : _secure = secure ?? const FlutterSecureStorage(),
      super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final raw = _prefs!.getString(_prefsKey);
      if (raw == null || raw.isEmpty) {
        state = const AsyncValue.data([]);
        return;
      }
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final accounts = <S3Account>[];
      for (final meta in list) {
        final id = meta['id'] as String;
        final secret = await _secure.read(key: _secretKey(id)) ?? '';
        final token = await _secure.read(key: _tokenKey(id));
        accounts.add(
          S3Account.fromJson(
            meta,
            secretKey: secret,
            sessionToken: (token == null || token.isEmpty) ? null : token,
          ),
        );
      }
      state = AsyncValue.data(accounts);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  static String _secretKey(String id) => 'clouddock.secret.$id';
  static String _tokenKey(String id) => 'clouddock.token.$id';

  Future<void> _persist(List<S3Account> accounts) async {
    _prefs ??= await SharedPreferences.getInstance();
    final metas = accounts.map((a) => a.toJson()).toList();
    await _prefs!.setString(_prefsKey, jsonEncode(metas));
    for (final a in accounts) {
      await _secure.write(key: _secretKey(a.id), value: a.secretKey);
      if (a.sessionToken != null && a.sessionToken!.isNotEmpty) {
        await _secure.write(key: _tokenKey(a.id), value: a.sessionToken);
      } else {
        await _secure.delete(key: _tokenKey(a.id));
      }
    }
  }

  List<S3Account> get _current => state.valueOrNull ?? [];

  S3Account? byId(String id) {
    try {
      return _current.firstWhere((a) => a.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Create with a fresh id; returns the created account.
  Future<S3Account> add({
    required String name,
    required ProviderType provider,
    required String endpoint,
    required String region,
    required String accessKey,
    required String secretKey,
    String? sessionToken,
    required bool usePathStyle,
    required bool useSSL,
    int? port,
  }) async {
    final account = S3Account(
      id: _uuid.v4(),
      name: name.trim(),
      provider: provider,
      endpoint: endpoint.trim(),
      region: region.trim().isEmpty ? provider.defaultRegion : region.trim(),
      accessKey: accessKey.trim(),
      secretKey: secretKey,
      sessionToken: (sessionToken == null || sessionToken.trim().isEmpty)
          ? null
          : sessionToken.trim(),
      usePathStyle: usePathStyle,
      useSSL: useSSL,
      port: port,
    );
    final next = [..._current, account];
    await _persist(next);
    state = AsyncValue.data(next);
    return account;
  }

  Future<void> update(S3Account updated) async {
    final next = _current.map((a) => a.id == updated.id ? updated : a).toList();
    await _persist(next);
    state = AsyncValue.data(next);
  }

  Future<void> remove(String id) async {
    final next = _current.where((a) => a.id != id).toList();
    await _persist(next);
    await _secure.delete(key: _secretKey(id));
    await _secure.delete(key: _tokenKey(id));
    state = AsyncValue.data(next);
  }

  /// Validate credentials with ListBuckets; throws S3Exception on failure.
  Future<int> testConnection(S3Account account) async {
    final client = S3Client(account);
    try {
      final buckets = await client.listBuckets();
      return buckets.length;
    } finally {
      client.close();
    }
  }
}

final accountStoreProvider =
    StateNotifierProvider<AccountStore, AsyncValue<List<S3Account>>>(
      (ref) => AccountStore(),
    );

/// Convenience: single account by id (null while loading/missing).
final accountByIdProvider = Provider.family<S3Account?, String>((ref, id) {
  final accounts = ref.watch(accountStoreProvider).valueOrNull;
  if (accounts == null) return null;
  try {
    return accounts.firstWhere((a) => a.id == id);
  } catch (_) {
    return null;
  }
});
