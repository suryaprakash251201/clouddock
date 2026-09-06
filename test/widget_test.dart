// App smoke test: boots to accounts screen empty state.

import 'package:clouddock/src/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('boots to CloudDock accounts screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: CloudDockApp()));
    await tester.pumpAndSettle();
    expect(find.text('CloudDock'), findsWidgets);
    // Empty state or list — either proves boot works.
    expect(
      find.textContaining('No storage accounts yet').evaluate().isNotEmpty ||
          find.byType(ListTile).evaluate().isNotEmpty ||
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty,
      isTrue,
    );
  });
}
