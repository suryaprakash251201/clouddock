// Tests for object details, tags, versioning, presigned upload links, and
// the shared byte formatter.

import 'package:clouddock/src/core/s3/s3_account.dart';
import 'package:clouddock/src/core/s3/s3_client.dart';
import 'package:clouddock/src/core/s3/s3_models.dart';
import 'package:clouddock/src/core/utils/format.dart';
import 'package:clouddock/src/features/transfers/transfer_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

S3Account testAccount({
  String endpoint = 's3.us-east-1.amazonaws.com',
  String region = 'us-east-1',
  bool pathStyle = false,
}) => S3Account(
  id: 'test',
  name: 'test',
  provider: ProviderType.aws,
  endpoint: endpoint,
  region: region,
  accessKey: 'AKID',
  secretKey: 'SECRET',
  usePathStyle: pathStyle,
  useSSL: true,
);

void main() {
  group('formatBytes', () {
    test('formats units', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('null is empty (for conditional joins)', () {
      expect(formatBytes(null), '');
    });

    test('short form drops decimals for large values', () {
      expect(formatBytesShort(512), '512 B');
      expect(formatBytesShort(1536), '1.5 KB');
      expect(formatBytesShort(150 * 1024 * 1024), '150 MB');
    });
  });

  group('headObjectDetails', () {
    test('parses metadata, content type, version id', () async {
      late http.Request seen;
      final mock = MockClient((req) async {
        seen = req;
        return http.Response(
          '',
          200,
          headers: {
            'content-length': '1234',
            'content-type': 'image/png',
            'etag': '"abc123"',
            'last-modified': 'Wed, 01 Jan 2025 10:00:00 GMT',
            'x-amz-storage-class': 'STANDARD_IA',
            'x-amz-version-id': 'v9',
            'x-amz-meta-camera': 'phone',
            'cache-control': 'max-age=60',
          },
        );
      });
      final client = S3Client(testAccount(), mock);
      final details = await client.headObjectDetails('b', 'photos/a.png');
      expect(details, isNotNull);
      expect(seen.method, 'HEAD');
      expect(details!.size, 1234);
      expect(details.contentType, 'image/png');
      expect(details.etag, 'abc123');
      expect(details.storageClass, 'STANDARD_IA');
      expect(details.versionId, 'v9');
      expect(details.cacheControl, 'max-age=60');
      expect(details.metadata, {'camera': 'phone'});
      expect(details.lastModified, isNotNull);
      client.close();
    });

    test('404 returns null', () async {
      final mock = MockClient((_) async => http.Response('', 404));
      final client = S3Client(testAccount(), mock);
      expect(await client.headObjectDetails('b', 'missing'), isNull);
      client.close();
    });

    test('headObject still maps to S3Object', () async {
      final mock = MockClient(
        (_) async => http.Response(
          '',
          200,
          headers: {'content-length': '42', 'etag': '"x"'},
        ),
      );
      final client = S3Client(testAccount(), mock);
      final obj = await client.headObject('b', 'k');
      expect(obj!.size, 42);
      expect(obj.etag, 'x');
      client.close();
    });
  });

  group('listObjectVersions', () {
    const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<ListVersionsResult>
  <IsTruncated>true</IsTruncated>
  <NextKeyMarker>photos/a.jpg</NextKeyMarker>
  <NextVersionIdMarker>v2</NextVersionIdMarker>
  <Version>
    <Key>photos/a.jpg</Key><VersionId>v1</VersionId><IsLatest>false</IsLatest>
    <LastModified>2024-03-01T10:00:00.000Z</LastModified>
    <ETag>"e1"</ETag><Size>100</Size><StorageClass>STANDARD</StorageClass>
    <Owner><DisplayName>alice</DisplayName></Owner>
  </Version>
  <DeleteMarker>
    <Key>photos/a.jpg</Key><VersionId>v2</VersionId><IsLatest>true</IsLatest>
    <LastModified>2024-04-01T10:00:00.000Z</LastModified>
    <Owner><DisplayName>alice</DisplayName></Owner>
  </DeleteMarker>
</ListVersionsResult>''';

    test('parses versions + delete markers + pagination', () async {
      late http.Request seen;
      final mock = MockClient((req) async {
        seen = req;
        return http.Response(xml, 200);
      });
      final client = S3Client(testAccount(), mock);
      final result = await client.listObjectVersions(
        'b',
        prefix: 'photos/a.jpg',
      );
      expect(seen.url.queryParameters['versions'], '');
      expect(seen.url.queryParameters['prefix'], 'photos/a.jpg');
      expect(result.versions, hasLength(2));
      final v1 = result.versions.first;
      expect(v1.versionId, 'v1');
      expect(v1.isLatest, isFalse);
      expect(v1.isDeleteMarker, isFalse);
      expect(v1.size, 100);
      expect(v1.storageClass, 'STANDARD');
      expect(v1.owner, 'alice');
      expect(v1.isRestorable, isTrue);
      expect(v1.shortVersionId, 'v1');
      final marker = result.versions.last;
      expect(marker.isDeleteMarker, isTrue);
      expect(marker.isLatest, isTrue);
      expect(marker.isRestorable, isFalse);
      expect(result.isTruncated, isTrue);
      expect(result.nextKeyMarker, 'photos/a.jpg');
      expect(result.nextVersionIdMarker, 'v2');
      client.close();
    });

    test('sends pagination markers', () async {
      late http.Request seen;
      final mock = MockClient((req) async {
        seen = req;
        return http.Response('<ListVersionsResult/>', 200);
      });
      final client = S3Client(testAccount(), mock);
      await client.listObjectVersions(
        'b',
        keyMarker: 'k/old',
        versionIdMarker: 'v7',
      );
      expect(seen.url.queryParameters['key-marker'], 'k/old');
      expect(seen.url.queryParameters['version-id-marker'], 'v7');
      client.close();
    });
  });

  group('object tags', () {
    test('getObjectTags parses TagSet', () async {
      late http.Request seen;
      final mock = MockClient((req) async {
        seen = req;
        return http.Response('''<?xml version="1.0"?><Tagging><TagSet>
          <Tag><Key>project</Key><Value>apollo</Value></Tag>
          <Tag><Key>env</Key><Value>prod</Value></Tag>
          </TagSet></Tagging>''', 200);
      });
      final client = S3Client(testAccount(), mock);
      final tags = await client.getObjectTags('b', 'k.txt');
      expect(seen.url.queryParameters['tagging'], '');
      expect(tags, [
        const S3ObjectTag('project', 'apollo'),
        const S3ObjectTag('env', 'prod'),
      ]);
      client.close();
    });

    test('putObjectTags sends XML body with checksum', () async {
      late http.Request seen;
      final mock = MockClient((req) async {
        seen = req;
        return http.Response('', 200);
      });
      final client = S3Client(testAccount(), mock);
      await client.putObjectTags('b', 'k.txt', [
        const S3ObjectTag('team', 'core'),
        const S3ObjectTag('note', 'a<b&c'),
      ]);
      expect(seen.method, 'PUT');
      expect(seen.url.queryParameters['tagging'], '');
      expect(seen.headers.containsKey('content-md5'), isTrue);
      expect(seen.body, contains('<Key>team</Key><Value>core</Value>'));
      expect(seen.body, contains('a&lt;b&amp;c'));
      client.close();
    });
  });

  group('versioning', () {
    test('getBucketVersioning parses status', () async {
      final statuses = {
        '<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>':
            BucketVersioning.enabled,
        '<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>':
            BucketVersioning.suspended,
        '<VersioningConfiguration/>': BucketVersioning.unversioned,
      };
      for (final entry in statuses.entries) {
        final mock = MockClient((_) async => http.Response(entry.key, 200));
        final client = S3Client(testAccount(), mock);
        expect(await client.getBucketVersioning('b'), entry.value);
        client.close();
      }
    });

    test('deleteObject with versionId adds query param', () async {
      late http.Request seen;
      final mock = MockClient((req) async {
        seen = req;
        return http.Response('', 204);
      });
      final client = S3Client(testAccount(), mock);
      await client.deleteObject('b', 'k', versionId: 'v3');
      expect(seen.method, 'DELETE');
      expect(seen.url.queryParameters['versionId'], 'v3');
      client.close();
    });

    test('restoreObjectVersion copies from ?versionId source', () async {
      late http.Request seen;
      final mock = MockClient((req) async {
        seen = req;
        return http.Response('', 200);
      });
      final client = S3Client(testAccount(), mock);
      await client.restoreObjectVersion('b', 'photos/a.jpg', 'v1');
      expect(seen.method, 'PUT');
      final source = seen.headers['x-amz-copy-source']!;
      expect(source, contains('/b/photos/a.jpg'));
      expect(source, contains('versionId=v1'));
      expect(seen.headers['x-amz-metadata-directive'], 'COPY');
      client.close();
    });
  });

  group('presigned URLs', () {
    test('presignedPut signs with PUT method', () {
      final client = S3Client(testAccount());
      final uri = client.presignedPut(
        'b',
        'incoming/report.txt',
        expiresSeconds: 900,
        now: DateTime.utc(2025, 1, 1, 12),
      );
      expect(uri.queryParameters['X-Amz-Signature'], hasLength(64));
      expect(uri.queryParameters['X-Amz-Expires'], '900');
      expect(uri.path, '/incoming/report.txt');
      client.close();
    });

    test('GET and PUT signatures differ for the same key', () {
      final client = S3Client(testAccount());
      final now = DateTime.utc(2025, 1, 1, 12);
      final get = client.presignedGet('b', 'k', now: now);
      final put = client.presignedPut('b', 'k', now: now);
      expect(
        get.queryParameters['X-Amz-Signature'],
        isNot(put.queryParameters['X-Amz-Signature']),
      );
      client.close();
    });

    test('presignedGet supports a versionId', () {
      final client = S3Client(testAccount());
      final uri = client.presignedGet('b', 'k', versionId: 'v1');
      expect(uri.queryParameters['versionId'], 'v1');
      expect(uri.queryParameters['X-Amz-Signature'], hasLength(64));
      client.close();
    });
  });

  group('TransferTask versioning', () {
    test('copyWith keeps versionId for downloads', () {
      const t = TransferTask(
        id: '1',
        type: TransferType.download,
        accountId: 'a',
        bucket: 'b',
        key: 'k',
        localPath: '/tmp/k',
        versionId: 'v1234567890',
      );
      final running = t.copyWith(status: TransferStatus.running, progress: 0.5);
      expect(running.versionId, 'v1234567890');
      expect(running.status, TransferStatus.running);
      expect(running.progress, 0.5);
    });
  });
}
