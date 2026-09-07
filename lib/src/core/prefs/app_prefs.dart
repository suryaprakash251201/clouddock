// App-wide persisted prefs: theme mode, default view mode, link expiry,
// app-lock toggle. Backed by SharedPreferences, exposed via Riverpod.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ViewMode { grid, list }

const _kViewMode = 'clouddock.viewMode.v1';
const _kThemeMode = 'clouddock.themeMode.v1';
const _kLinkExpiry = 'clouddock.linkExpiry.v1';
const _kAppLock = 'clouddock.appLock.v1';

class ViewModeNotifier extends StateNotifier<ViewMode> {
  ViewModeNotifier() : super(ViewMode.grid) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kViewMode);
      if (raw == 'list') state = ViewMode.list;
      // Default is grid.
    } catch (_) {
      // Keep default.
    }
  }

  Future<void> set(ViewMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kViewMode, mode.name);
    } catch (_) {}
  }

  void toggle() => set(state == ViewMode.grid ? ViewMode.list : ViewMode.grid);
}

final viewModeProvider = StateNotifierProvider<ViewModeNotifier, ViewMode>(
  (ref) => ViewModeNotifier(),
);

class AppThemeModeNotifier extends StateNotifier<ThemeMode> {
  AppThemeModeNotifier() : super(ThemeMode.system) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = switch (prefs.getString(_kThemeMode)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {}
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThemeMode, switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      });
    } catch (_) {}
  }
}

final appThemeModeProvider =
    StateNotifierProvider<AppThemeModeNotifier, ThemeMode>(
      (ref) => AppThemeModeNotifier(),
    );

/// Presigned share-link expiry in seconds. Default 1h.
class LinkExpiryNotifier extends StateNotifier<int> {
  LinkExpiryNotifier() : super(3600) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(_kLinkExpiry);
      if (v != null && v > 0) state = v;
    } catch (_) {}
  }

  Future<void> set(int seconds) async {
    state = seconds;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLinkExpiry, seconds);
    } catch (_) {}
  }
}

final linkExpiryProvider = StateNotifierProvider<LinkExpiryNotifier, int>(
  (ref) => LinkExpiryNotifier(),
);

class AppLockNotifier extends StateNotifier<bool> {
  AppLockNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = prefs.getBool(_kAppLock) ?? false;
    } catch (_) {}
  }

  Future<void> set(bool enabled) async {
    state = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAppLock, enabled);
    } catch (_) {}
  }
}

final appLockProvider = StateNotifierProvider<AppLockNotifier, bool>(
  (ref) => AppLockNotifier(),
);

String describeExpiry(int seconds) {
  if (seconds < 3600) return '${seconds ~/ 60} min';
  if (seconds < 86400) return '${seconds ~/ 3600} hour(s)';
  return '${seconds ~/ 86400} day(s)';
}
