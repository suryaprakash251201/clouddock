// Viewer-kind mapping tests (pure Dart, no platform channels).

import 'package:clouddock/src/features/viewers/viewer_kind.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('viewerKindForKey', () {
    test('images', () {
      for (final ext in ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic']) {
        expect(
          viewerKindForKey('photos/a.$ext'),
          ViewerKind.image,
          reason: ext,
        );
      }
      expect(viewerKindForKey('photos/A.JPG'), ViewerKind.image);
    });

    test('text', () {
      for (final ext in ['txt', 'md', 'json', 'yaml', 'csv', 'log', 'dart']) {
        expect(viewerKindForKey('docs/a.$ext'), ViewerKind.text, reason: ext);
      }
    });

    test('pdf', () {
      expect(viewerKindForKey('docs/report.pdf'), ViewerKind.pdf);
      expect(viewerKindForKey('docs/report.PDF'), ViewerKind.pdf);
    });

    test('video', () {
      for (final ext in ['mp4', 'mov', 'webm', 'mkv']) {
        expect(viewerKindForKey('vid/a.$ext'), ViewerKind.video, reason: ext);
      }
    });

    test('unsupported or missing extension → null', () {
      expect(viewerKindForKey('archive.zip'), isNull);
      expect(viewerKindForKey('README'), isNull);
      expect(viewerKindForKey('folder/.hidden'), isNull);
      expect(viewerKindForKey('photos/noext.'), isNull);
    });

    test('uses basename, not folder names', () {
      expect(viewerKindForKey('mp4/file.txt'), ViewerKind.text);
    });
  });
}
