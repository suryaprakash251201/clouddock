// Home tab: quick actions, storage summary, recently opened files.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/prefs/app_prefs.dart';
import '../../core/storage/account_store.dart';
import '../../core/utils/format.dart';
import '../../ui/file_visuals.dart';
import '../../ui/floating_nav_bar.dart';
import '../../ui/glass.dart';
import '../favorites/favorites_store.dart';
import '../transfers/transfer_manager.dart';
import '../viewers/viewer_routes.dart';
import 'recent_files_store.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeState();
}

class _HomeState extends ConsumerState<HomeScreen> {
  bool _unlocked = false;
  bool _checkingLock = true;
  bool _authenticatedThisSession = false;
  bool _showAllFavorites = false;

  @override
  void initState() {
    super.initState();
    // Defer past the first frame so persisted prefs (app-lock flag) have a
    // chance to load before we decide to skip authentication.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkLock());
  }

  Future<void> _checkLock() async {
    final locked = ref.read(appLockProvider);
    if (!locked) {
      if (mounted) {
        setState(() {
          _unlocked = true;
          _checkingLock = false;
        });
      }
      return;
    }
    if (_authenticatedThisSession) {
      if (mounted) {
        setState(() {
          _unlocked = true;
          _checkingLock = false;
        });
      }
      return;
    }
    // Require biometrics/device credential each time Home is shown while
    // app-lock is enabled.
    try {
      final auth = LocalAuthentication();
      final canCheck = await auth.canCheckBiometrics;
      final isSupported = await auth.isDeviceSupported();
      if (!canCheck && !isSupported) {
        setState(() {
          _unlocked = true;
          _checkingLock = false;
        });
        return;
      }
      final ok = await auth.authenticate(
        localizedReason: 'Unlock CloudDock',
        biometricOnly: false,
      );
      if (mounted) {
        setState(() {
          _unlocked = ok;
          _checkingLock = false;
          if (ok) _authenticatedThisSession = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _unlocked = true;
          _checkingLock = false;
        });
      }
    }
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  void _openFavorite(BuildContext context, FavoriteFile f) {
    final account = ref.read(accountByIdProvider(f.accountId));
    if (account == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Account for "${f.name}" no longer exists')),
      );
      ref.read(favoritesProvider.notifier).remove(f.id);
      return;
    }
    final route = viewerRouteForKey(f.key);
    if (route == null) {
      final prefix = f.key.contains('/')
          ? f.key.substring(0, f.key.lastIndexOf('/') + 1)
          : '';
      context.push(
        '/s3/browse/${f.accountId}/${f.bucket}?prefix=${Uri.encodeComponent(prefix)}',
      );
      return;
    }
    context.push(
      viewerLocation(
        route: route,
        accountId: f.accountId,
        bucket: f.bucket,
        key: f.key,
      ),
    );
  }

  void _openRecent(BuildContext context, RecentFile r) {
    final account = ref.read(accountByIdProvider(r.accountId));
    if (account == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Account for "${r.name}" no longer exists')),
      );
      ref.read(recentFilesProvider.notifier).remove(r.id);
      return;
    }
    final route = viewerRouteForKey(r.key);
    if (route == null) {
      // No in-app viewer: jump to the containing folder.
      final prefix = r.key.contains('/')
          ? r.key.substring(0, r.key.lastIndexOf('/') + 1)
          : '';
      context.push(
        '/s3/browse/${r.accountId}/${r.bucket}?prefix=${Uri.encodeComponent(prefix)}',
      );
      return;
    }
    context.push(
      viewerLocation(
        route: route,
        accountId: r.accountId,
        bucket: r.bucket,
        key: r.key,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appLock = ref.watch(appLockProvider);
    // The persisted flag loads async: if it flips to true after we already
    // skipped auth on cold start, re-run the check instead of staying open.
    if (appLock && !_authenticatedThisSession && _unlocked && !_checkingLock) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _checkingLock = true);
          _checkLock();
        }
      });
    }
    if (_checkingLock) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_unlocked) {
      return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(title: const Text('CloudDock')),
        body: AppBackground(
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_rounded, size: 56),
                    const SizedBox(height: 16),
                    const Text(
                      'Locked',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('Authenticate to unlock CloudDock.'),
                    const SizedBox(height: 20),
                    GlowButton(
                      label: 'Unlock',
                      icon: Icons.fingerprint_rounded,
                      onPressed: () {
                        setState(() => _checkingLock = true);
                        _checkLock();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final accountsAsync = ref.watch(accountStoreProvider);
    final accounts = accountsAsync.valueOrNull ?? [];
    final transfers = ref.watch(transferManagerProvider);
    final activeCount = transfers
        .where(
          (t) =>
              t.status == TransferStatus.running ||
              t.status == TransferStatus.queued,
        )
        .length;
    final recents = ref.watch(recentFilesProvider);
    final favorites = ref.watch(favoritesProvider);
    // Prune recents/favorites whose account was deleted (post-frame to avoid
    // build loops).
    if (accountsAsync.hasValue) {
      final live = accounts.map((a) => a.id).toSet();
      if (recents.any((r) => !live.contains(r.accountId))) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => ref.read(recentFilesProvider.notifier).prune(live),
        );
      }
      if (favorites.any((f) => !live.contains(f.accountId))) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => ref.read(favoritesProvider.notifier).prune(live),
        );
      }
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          'CloudDock',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: () async {
              await ref.read(accountStoreProvider.notifier).refresh();
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                16,
                8,
                16,
                kFloatingNavBarClearance,
              ),
              children: [
                Glass(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _greeting(),
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.onSurface
                                    .withValues(alpha: 0.6),
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Your S3 files, one tap away.',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              children: [
                                StatusPill(
                                  label: '${accounts.length} account(s)',
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                if (activeCount > 0)
                                  StatusPill(
                                    label: '$activeCount active',
                                    color: Colors.orange,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        height: 64,
                        width: 64,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          gradient: const LinearGradient(
                            colors: [Color(0xFF2DD4BF), Color(0xFF6366F1)],
                          ),
                        ),
                        child: const Icon(
                          Icons.cloud_rounded,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                    ],
                  ),
                ),
                const SectionLabel('Quick actions'),
                Row(
                  children: [
                    Expanded(
                      child: _QuickAction(
                        icon: Icons.storage_rounded,
                        label: 'S3',
                        onTap: () => context.go('/s3'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _QuickAction(
                        icon: Icons.add_rounded,
                        label: 'Add account',
                        onTap: () => context.push('/s3/account'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _QuickAction(
                        icon: Icons.download_rounded,
                        label: 'Downloads',
                        badge: activeCount > 0 ? '$activeCount' : null,
                        onTap: () => context.go('/downloads'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _QuickAction(
                        icon: Icons.settings_rounded,
                        label: 'Settings',
                        onTap: () => context.go('/settings'),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Expanded(child: SectionLabel('Starred')),
                    if (favorites.length > 5)
                      TextButton(
                        onPressed: () => setState(
                          () => _showAllFavorites = !_showAllFavorites,
                        ),
                        child: Text(
                          _showAllFavorites
                              ? 'Show less'
                              : 'Show all (${favorites.length})',
                        ),
                      ),
                  ],
                ),
                if (favorites.isEmpty)
                  const Glass(
                    padding: EdgeInsets.all(18),
                    child: Row(
                      children: [
                        Icon(Icons.star_outline_rounded),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Star files from an object\'s details to pin them here.',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  for (final f
                      in _showAllFavorites ? favorites : favorites.take(5)) ...[
                    _FavoriteCard(
                      favorite: f,
                      onTap: () => _openFavorite(context, f),
                      onDismiss: () =>
                          ref.read(favoritesProvider.notifier).remove(f.id),
                    ),
                    const SizedBox(height: 10),
                  ],
                Row(
                  children: [
                    const Expanded(child: SectionLabel('Recently opened')),
                    if (recents.isNotEmpty)
                      TextButton(
                        onPressed: () =>
                            ref.read(recentFilesProvider.notifier).clear(),
                        child: const Text('Clear'),
                      ),
                  ],
                ),
                if (recents.isEmpty)
                  const Glass(
                    padding: EdgeInsets.all(18),
                    child: Row(
                      children: [
                        Icon(Icons.history_rounded),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Files you open or preview will show up here for quick access.',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  for (final r in recents) ...[
                    _RecentCard(
                      recent: r,
                      onTap: () => _openRecent(context, r),
                      onDismiss: () =>
                          ref.read(recentFilesProvider.notifier).remove(r.id),
                    ),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? badge;
  final VoidCallback onTap;
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Glass(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
      radius: 16,
      onTap: onTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (badge != null)
            Positioned(
              top: 0,
              right: 12,
              child: CircleAvatar(
                radius: 10,
                child: Text(badge!, style: const TextStyle(fontSize: 11)),
              ),
            ),
        ],
      ),
    );
  }
}

class _RecentCard extends StatelessWidget {
  final RecentFile recent;
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  const _RecentCard({
    required this.recent,
    required this.onTap,
    required this.onDismiss,
  });

  Color _tint() => fileTint(recent.key, const Color(0xFF2DD4BF));

  IconData _icon() => fileIcon(recent.key);

  @override
  Widget build(BuildContext context) {
    final tint = _tint();
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey(recent.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: scheme.error.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_outline_rounded),
      ),
      onDismissed: (_) => onDismiss(),
      child: Glass(
        padding: const EdgeInsets.all(12),
        radius: 16,
        onTap: onTap,
        child: Row(
          children: [
            Container(
              height: 42,
              width: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                color: tint.withValues(alpha: 0.18),
                border: Border.all(color: tint.withValues(alpha: 0.35)),
              ),
              child: Icon(_icon(), color: tint, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    recent.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${recent.accountName} • ${recent.bucket} • ${formatBytes(recent.size)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

class _FavoriteCard extends StatelessWidget {
  final FavoriteFile favorite;
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  const _FavoriteCard({
    required this.favorite,
    required this.onTap,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = fileTint(favorite.key, const Color(0xFFFBBF24));
    return Dismissible(
      key: ValueKey('fav-${favorite.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: scheme.error.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.star_outline_rounded),
      ),
      onDismissed: (_) => onDismiss(),
      child: Glass(
        padding: const EdgeInsets.all(12),
        radius: 16,
        onTap: onTap,
        child: Row(
          children: [
            Container(
              height: 42,
              width: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                color: tint.withValues(alpha: 0.18),
                border: Border.all(color: tint.withValues(alpha: 0.35)),
              ),
              child: Icon(fileIcon(favorite.key), color: tint, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    favorite.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${favorite.accountName} • ${favorite.bucket} • ${formatBytes(favorite.size)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.star_rounded, color: Color(0xFFFBBF24), size: 20),
          ],
        ),
      ),
    );
  }
}
