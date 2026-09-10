// Settings: appearance, browsing defaults, storage, security, diagnostics.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_info.dart';
import '../../core/prefs/app_prefs.dart';
import '../../core/storage/account_store.dart';
import '../../ui/floating_nav_bar.dart';
import '../../ui/glass.dart';
import '../favorites/favorites_store.dart';
import '../home/recent_files_store.dart';
import '../transfers/transfer_manager.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(accountStoreProvider).valueOrNull?.length ?? 0;
    final themeMode = ref.watch(appThemeModeProvider);
    final viewMode = ref.watch(viewModeProvider);
    final linkExpiry = ref.watch(linkExpiryProvider);
    final appLock = ref.watch(appLockProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              16,
              8,
              16,
              kFloatingNavBarClearance,
            ),
            children: [
              const SectionLabel('General'),
              Glass(
                padding: const EdgeInsets.all(6),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.cloud_outlined),
                      title: const Text('Connected accounts'),
                      trailing: StatusPill(
                        label: '$count',
                        color: scheme.primary,
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.security_outlined),
                      title: const Text('Secrets stay on-device'),
                      subtitle: const Text(
                        'Access keys in Keychain/Keystore, metadata only in app prefs. Nothing leaves the phone except S3 API calls.',
                      ),
                    ),
                  ],
                ),
              ),
              const SectionLabel('Appearance'),
              Glass(
                padding: const EdgeInsets.all(6),
                child: RadioGroup<ThemeMode>(
                  groupValue: themeMode,
                  onChanged: (v) {
                    if (v != null) {
                      ref.read(appThemeModeProvider.notifier).set(v);
                    }
                  },
                  child: const Column(
                    children: [
                      RadioListTile<ThemeMode>(
                        title: Text('System'),
                        secondary: Icon(Icons.brightness_auto_outlined),
                        value: ThemeMode.system,
                      ),
                      RadioListTile<ThemeMode>(
                        title: Text('Light'),
                        secondary: Icon(Icons.light_mode_outlined),
                        value: ThemeMode.light,
                      ),
                      RadioListTile<ThemeMode>(
                        title: Text('Dark'),
                        secondary: Icon(Icons.dark_mode_outlined),
                        value: ThemeMode.dark,
                      ),
                    ],
                  ),
                ),
              ),
              const SectionLabel('Browsing'),
              Glass(
                padding: const EdgeInsets.all(6),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.grid_view_rounded),
                      title: const Text('Default view'),
                      subtitle: const Text(
                        'Buckets and files open in this layout.',
                      ),
                      trailing: SegmentedButton<ViewMode>(
                        segments: const [
                          ButtonSegment(
                            value: ViewMode.grid,
                            icon: Icon(Icons.grid_view_rounded, size: 18),
                          ),
                          ButtonSegment(
                            value: ViewMode.list,
                            icon: Icon(Icons.view_list_rounded, size: 18),
                          ),
                        ],
                        selected: {viewMode},
                        showSelectedIcon: false,
                        onSelectionChanged: (s) =>
                            ref.read(viewModeProvider.notifier).set(s.first),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.link_rounded),
                      title: const Text('Share link expiry'),
                      subtitle: Text(
                        'Presigned links last ${describeExpiry(linkExpiry)}.',
                      ),
                      trailing: DropdownButton<int>(
                        value: linkExpiry,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: 900, child: Text('15 min')),
                          DropdownMenuItem(value: 3600, child: Text('1 hour')),
                          DropdownMenuItem(
                            value: 86400,
                            child: Text('24 hours'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            ref.read(linkExpiryProvider.notifier).set(v);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SectionLabel('Storage'),
              Glass(
                padding: const EdgeInsets.all(6),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.history_rounded),
                      title: const Text('Clear recent history'),
                      subtitle: const Text('Removes Home → Recently opened.'),
                      onTap: () async {
                        await ref.read(recentFilesProvider.notifier).clear();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Recent history cleared'),
                            ),
                          );
                        }
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.star_outline_rounded),
                      title: const Text('Clear starred files'),
                      subtitle: const Text('Removes Home → Starred.'),
                      onTap: () async {
                        await ref.read(favoritesProvider.notifier).clear();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Starred files cleared'),
                            ),
                          );
                        }
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.download_done_rounded),
                      title: const Text('Clear finished transfers'),
                      onTap: () {
                        ref
                            .read(transferManagerProvider.notifier)
                            .clearFinished();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Finished transfers cleared'),
                          ),
                        );
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.folder_open_rounded),
                      title: const Text('Download location'),
                      subtitle: FutureBuilder<String>(
                        future: _downloadDir(),
                        builder: (c, snap) => Text(
                          snap.data ?? 'Loading…',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SectionLabel('Security'),
              Glass(
                padding: const EdgeInsets.all(6),
                child: SwitchListTile(
                  secondary: const Icon(Icons.fingerprint_rounded),
                  title: const Text('App lock'),
                  subtitle: const Text(
                    'Require biometrics or device credential to open Home.',
                  ),
                  value: appLock,
                  onChanged: (v) => _toggleAppLock(context, ref, v),
                ),
              ),
              const SectionLabel('About'),
              const Glass(
                padding: EdgeInsets.all(6),
                child: ListTile(
                  leading: Icon(Icons.info_outline_rounded),
                  title: Text(appVersionLabel),
                  subtitle: Text(
                    'S3 browser for AWS S3, Cloudflare R2, MinIO, Wasabi, Backblaze B2 + any S3-compatible server.',
                  ),
                ),
              ),
              const SectionLabel('Tips'),
              const Glass(
                padding: EdgeInsets.all(16),
                child: Text(
                  '• R2 uses region "auto" and path-style.\n'
                  '• MinIO dev servers can disable SSL.\n'
                  '• If listing fails, toggle path-style in account settings.\n'
                  '• Long-press a file for details, versions, share, rename, delete.\n'
                  '• Open a file\'s Details to view custom metadata and edit tags.\n'
                  '• Version history can restore or permanently delete old versions.\n'
                  '• Use Upload → Create upload link to receive files from anyone.\n'
                  '• Long-press → Select (or the checkbox) for batch download/delete.',
                  style: TextStyle(fontSize: 13, height: 1.6),
                ),
              ),
              const SectionLabel('Diagnostics'),
              Glass(
                padding: const EdgeInsets.all(6),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.bug_report_outlined),
                      title: const Text('Export error log'),
                      subtitle: const Text(
                        'Shares the on-device crash.log (no keys or file contents).',
                      ),
                      trailing: const Icon(Icons.share_outlined),
                      onTap: () => _shareLog(context),
                    ),
                    ListTile(
                      leading: const Icon(Icons.delete_outline_rounded),
                      title: const Text('Clear error log'),
                      onTap: () => _clearLog(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<String> _downloadDir() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return '${dir.path}/CloudDock';
    } catch (_) {
      return 'Unavailable';
    }
  }

  static Future<void> _toggleAppLock(
    BuildContext context,
    WidgetRef ref,
    bool enable,
  ) async {
    if (!enable) {
      await ref.read(appLockProvider.notifier).set(false);
      return;
    }
    try {
      final auth = LocalAuthentication();
      final ok = await auth.authenticate(
        localizedReason: 'Enable CloudDock app lock',
        biometricOnly: false,
      );
      if (ok) {
        await ref.read(appLockProvider.notifier).set(true);
      } else if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Authentication failed')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('App lock unavailable: $e')));
      }
    }
  }

  static Future<File> _logFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/CloudDock/crash.log');
  }

  static Future<void> _shareLog(BuildContext context) async {
    try {
      final file = await _logFile();
      if (!await file.exists()) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('No errors logged yet')));
        }
        return;
      }
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: 'CloudDock error log'),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  static Future<void> _clearLog(BuildContext context) async {
    try {
      final file = await _logFile();
      if (await file.exists()) await file.delete();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Error log cleared')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Clear failed: $e')));
      }
    }
  }
}
