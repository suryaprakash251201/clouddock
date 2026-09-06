// App shell: theme + go_router.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'features/accounts/account_form_screen.dart';
import 'features/accounts/accounts_screen.dart';
import 'features/browser/browser_screen.dart';
import 'features/buckets/buckets_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/transfers/transfers_screen.dart';
import 'features/viewers/image_viewer_screen.dart';
import 'features/viewers/pdf_viewer_screen.dart';
import 'features/viewers/text_editor_screen.dart';
import 'features/viewers/video_player_screen.dart';
import 'ui/theme.dart';

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const AccountsScreen(),
      routes: [
        GoRoute(
          path: 'account',
          builder: (context, state) =>
              AccountFormScreen(accountId: state.uri.queryParameters['id']),
        ),
        GoRoute(
          path: 'buckets/:accountId',
          builder: (context, state) =>
              BucketsScreen(accountId: state.pathParameters['accountId']!),
        ),
        GoRoute(
          path: 'browse/:accountId/:bucket',
          builder: (context, state) => BrowserScreen(
            accountId: state.pathParameters['accountId']!,
            bucket: state.pathParameters['bucket']!,
            initialPrefix: state.uri.queryParameters['prefix'] ?? '',
          ),
        ),
        GoRoute(
          path: 'transfers',
          builder: (context, state) => const TransfersScreen(),
        ),
        GoRoute(
          path: 'view/image',
          builder: (context, state) {
            final q = state.uri.queryParameters;
            return ImageViewerScreen(
              accountId: q['accountId']!,
              bucket: q['bucket']!,
              objectKey: q['key']!,
            );
          },
        ),
        GoRoute(
          path: 'view/text',
          builder: (context, state) {
            final q = state.uri.queryParameters;
            return TextEditorScreen(
              accountId: q['accountId']!,
              bucket: q['bucket']!,
              objectKey: q['key']!,
            );
          },
        ),
        GoRoute(
          path: 'view/pdf',
          builder: (context, state) {
            final q = state.uri.queryParameters;
            return PdfViewerScreen(
              accountId: q['accountId']!,
              bucket: q['bucket']!,
              objectKey: q['key']!,
            );
          },
        ),
        GoRoute(
          path: 'view/video',
          builder: (context, state) {
            final q = state.uri.queryParameters;
            return VideoPlayerScreen(
              accountId: q['accountId']!,
              bucket: q['bucket']!,
              objectKey: q['key']!,
            );
          },
        ),
        GoRoute(
          path: 'settings',
          builder: (context, state) => const SettingsScreen(),
        ),
      ],
    ),
  ],
);

class CloudDockApp extends StatelessWidget {
  const CloudDockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'CloudDock',
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.system,
      routerConfig: _router,
    );
  }
}
