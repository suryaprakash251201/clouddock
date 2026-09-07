import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';

Future<void> _logError(Object error, StackTrace stack) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/CloudDock/crash.log');
    await file.parent.create(recursive: true);
    final entry = '${DateTime.now().toIso8601String()} $error\n$stack\n---\n';
    // Best effort, cap log at ~200 KB.
    if (await file.exists() && await file.length() > 200 * 1024) {
      await file.writeAsString(entry);
    } else {
      await file.writeAsString(entry, mode: FileMode.append);
    }
  } catch (_) {
    // Never crash the app while reporting a crash.
  }
}

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        unawaited(
          _logError(details.exception, details.stack ?? StackTrace.empty),
        );
      };
      runApp(const ProviderScope(child: CloudDockApp()));
    },
    (error, stack) {
      unawaited(_logError(error, stack));
    },
  );
}
