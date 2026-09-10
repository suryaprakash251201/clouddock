// App smoke test: boots to Home tab with the floating bottom navigation.

import 'package:clouddock/src/app.dart';
import 'package:clouddock/src/ui/floating_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(const ProviderScope(child: CloudDockApp()));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('boots to CloudDock home screen', (tester) async {
    await pumpApp(tester);
    expect(find.text('CloudDock'), findsWidgets);
    // Floating navigation proves the new shell works.
    expect(find.byType(FloatingNavBar), findsOneWidget);
    expect(find.text('Home'), findsWidgets);
    expect(find.text('S3'), findsWidgets);
    expect(find.text('Downloads'), findsWidgets);
    // Home content: quick actions + recents section.
    expect(
      find.textContaining('Recently opened').evaluate().isNotEmpty ||
          find.textContaining('Your S3 files').evaluate().isNotEmpty ||
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty,
      isTrue,
    );
  });

  testWidgets('bottom nav floats inside rounded glass capsule', (tester) async {
    await pumpApp(tester);
    final nav = find.byType(FloatingNavBar);
    expect(nav, findsOneWidget);
    expect(
      find.descendant(of: nav, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );

    final clip = find
        .descendant(of: nav, matching: find.byType(ClipRRect))
        .first;
    final rect = tester.getRect(clip);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    // Inset on all sides => floating card, not an edge-to-edge bar.
    expect(rect.left, greaterThan(0));
    expect(rect.right, lessThan(screen.width));
    expect(rect.bottom, lessThan(screen.height));
    expect(rect.height, kFloatingNavBarHeight);
  });

  testWidgets('tapping a destination switches branches', (tester) async {
    await pumpApp(tester);
    final settingsTab = find.descendant(
      of: find.byType(FloatingNavBar),
      matching: find.text('Settings'),
    );
    await tester.tap(settingsTab);
    await tester.pumpAndSettle();
    expect(find.text('Connected accounts'), findsOneWidget);

    final s3Tab = find.descendant(
      of: find.byType(FloatingNavBar),
      matching: find.text('S3'),
    );
    await tester.tap(s3Tab);
    await tester.pumpAndSettle();
    expect(find.text('No storage accounts yet'), findsOneWidget);
  });

  testWidgets('shell nav hides when a screen takes over the bottom area', (
    tester,
  ) async {
    await pumpApp(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CloudDockApp)),
    );
    container.read(shellNavVisibleProvider.notifier).state = false;
    await tester.pumpAndSettle();
    expect(find.byType(FloatingNavBar), findsNothing);

    container.read(shellNavVisibleProvider.notifier).state = true;
    await tester.pumpAndSettle();
    expect(find.byType(FloatingNavBar), findsOneWidget);
  });
}
