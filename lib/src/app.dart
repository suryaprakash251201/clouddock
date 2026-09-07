// App shell: theme + go_router with bottom navigation.
// Tabs: Home | S3 | Downloads | Settings. Viewers stay top-level so any tab
// can push them.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/prefs/app_prefs.dart';
import 'features/accounts/account_form_screen.dart';
import 'features/accounts/accounts_screen.dart';
import 'features/browser/browser_screen.dart';
import 'features/buckets/buckets_screen.dart';
import 'features/home/home_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/transfers/transfer_manager.dart';
import 'features/transfers/transfers_screen.dart';
import 'features/viewers/audio_player_screen.dart';
import 'features/viewers/image_viewer_screen.dart';
import 'features/viewers/pdf_viewer_screen.dart';
import 'features/viewers/text_editor_screen.dart';
import 'features/viewers/video_player_screen.dart';
import 'ui/theme.dart';

Widget _viewerRoute(
  String kind,
  String accountId,
  String bucket,
  String objectKey,
) {
  return switch (kind) {
    'image' => ImageViewerScreen(
      accountId: accountId,
      bucket: bucket,
      objectKey: objectKey,
    ),
    'text' => TextEditorScreen(
      accountId: accountId,
      bucket: bucket,
      objectKey: objectKey,
    ),
    'pdf' => PdfViewerScreen(
      accountId: accountId,
      bucket: bucket,
      objectKey: objectKey,
    ),
    'audio' => AudioPlayerScreen(
      accountId: accountId,
      bucket: bucket,
      objectKey: objectKey,
    ),
    _ => VideoPlayerScreen(
      accountId: accountId,
      bucket: bucket,
      objectKey: objectKey,
    ),
  };
}

final _router = GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(path: '/', redirect: (_, _) => '/home'),
    // Back-compat: old top-level locations redirect into the S3 branch.
    GoRoute(path: '/transfers', redirect: (_, _) => '/downloads'),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/home',
              builder: (context, state) => const HomeScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/s3',
              builder: (context, state) => const AccountsScreen(),
              routes: [
                GoRoute(
                  path: 'account',
                  builder: (context, state) => AccountFormScreen(
                    accountId: state.uri.queryParameters['id'],
                  ),
                ),
                GoRoute(
                  path: 'buckets/:accountId',
                  builder: (context, state) => BucketsScreen(
                    accountId: state.pathParameters['accountId']!,
                  ),
                ),
                GoRoute(
                  path: 'browse/:accountId/:bucket',
                  builder: (context, state) => BrowserScreen(
                    accountId: state.pathParameters['accountId']!,
                    bucket: state.pathParameters['bucket']!,
                    initialPrefix: state.uri.queryParameters['prefix'] ?? '',
                  ),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/downloads',
              builder: (context, state) => const TransfersScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsScreen(),
            ),
          ],
        ),
      ],
    ),
    // Viewers are top-level so Home recents + Browser can both push them.
    for (final kind in ['image', 'text', 'pdf', 'video', 'audio'])
      GoRoute(
        path: '/view/$kind',
        builder: (context, state) {
          final q = state.uri.queryParameters;
          return _viewerRoute(kind, q['accountId']!, q['bucket']!, q['key']!);
        },
      ),
  ],
);

class AppShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;
  const AppShell({super.key, required this.navigationShell});

  void _goBranch(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(transferManagerProvider);
    final activeCount = transfers
        .where(
          (t) =>
              t.status == TransferStatus.running ||
              t.status == TransferStatus.queued,
        )
        .length;
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: _goBranch,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.cloud_outlined),
            selectedIcon: Icon(Icons.cloud_rounded),
            label: 'S3',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: activeCount > 0,
              label: Text('$activeCount'),
              child: const Icon(Icons.download_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: activeCount > 0,
              label: Text('$activeCount'),
              child: const Icon(Icons.download_rounded),
            ),
            label: 'Downloads',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class CloudDockApp extends ConsumerWidget {
  const CloudDockApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(appThemeModeProvider);
    return MaterialApp.router(
      title: 'CloudDock',
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      routerConfig: _router,
    );
  }
}
