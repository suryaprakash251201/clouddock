// Shared file-type visuals (icon + tint) for browser, home, and sheets.

import 'package:flutter/material.dart';

import '../features/viewers/viewer_kind.dart';

/// Accent color for [key] based on its viewer kind; [fallback] for unknown.
Color fileTint(String key, Color fallback) {
  return switch (viewerKindForKey(key)) {
    ViewerKind.image => const Color(0xFF34D399),
    ViewerKind.video => const Color(0xFFF472B6),
    ViewerKind.audio => const Color(0xFFA78BFA),
    ViewerKind.pdf => const Color(0xFFF87171),
    ViewerKind.text => const Color(0xFF60A5FA),
    null => fallback,
  };
}

IconData fileIcon(String key) {
  return switch (viewerKindForKey(key)) {
    ViewerKind.image => Icons.image_rounded,
    ViewerKind.video => Icons.movie_rounded,
    ViewerKind.audio => Icons.music_note_rounded,
    ViewerKind.pdf => Icons.picture_as_pdf_rounded,
    ViewerKind.text => Icons.description_rounded,
    null => Icons.insert_drive_file_rounded,
  };
}
