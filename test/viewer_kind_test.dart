// Viewer-kind mapping tests (pure Dart, no platform channels).

import 'package:clouddock/src/features/viewers/viewer_kind.dart';
import 'package:clouddock/src/features/viewers/viewer_routes.dart';
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

    test('audio', () {
      for (final ext in [
        'mp3',
        'm4a',
        'aac',
        'wav',
        'ogg',
        'oga',
        'opus',
        'flac',
        'aiff',
        'amr',
        'wma',
      ]) {
        expect(viewerKindForKey('music/a.$ext'), ViewerKind.audio, reason: ext);
      }
      expect(viewerKindForKey('music/A.MP3'), ViewerKind.audio);
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

  group('viewer routes', () {
    test('maps every kind to a top-level route', () {
      expect(viewerRouteForKey('a.jpg'), '/view/image');
      expect(viewerRouteForKey('a.txt'), '/view/text');
      expect(viewerRouteForKey('a.pdf'), '/view/pdf');
      expect(viewerRouteForKey('a.mp4'), '/view/video');
      expect(viewerRouteForKey('a.mp3'), '/view/audio');
      expect(viewerRouteForKey('archive.zip'), isNull);
    });

    test('viewerLocation query-encodes account/bucket/key', () {
      final loc = viewerLocation(
        route: '/view/image',
        accountId: 'acc 1',
        bucket: 'my bucket',
        key: 'photos/a b.jpg',
      );
      expect(loc, startsWith('/view/image?'));
      final uri = Uri.parse(loc);
      expect(uri.queryParameters['accountId'], 'acc 1');
      expect(uri.queryParameters['bucket'], 'my bucket');
      expect(uri.queryParameters['key'], 'photos/a b.jpg');
    });
  });
}
