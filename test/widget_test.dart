// App smoke test: boots to Home tab with bottom navigation.

import 'package:clouddock/src/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('boots to CloudDock home screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: CloudDockApp()));
    await tester.pumpAndSettle();
    expect(find.text('CloudDock'), findsWidgets);
    // Bottom navigation proves the new shell works.
    expect(find.text('Home'), findsWidgets);
    expect(find.text('S3'), findsWidgets);
    expect(find.text('Downloads'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
    // Home content: quick actions + recents section.
    expect(
      find.textContaining('Recently opened').evaluate().isNotEmpty ||
          find.textContaining('Your S3 files').evaluate().isNotEmpty ||
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty,
      isTrue,
    );
  });
}
