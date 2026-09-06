// S3Client URI + XML parsing tests with a mock http client.

import 'package:clouddock/src/core/s3/s3_account.dart';
import 'package:clouddock/src/core/s3/s3_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

S3Account testAccount({
  ProviderType provider = ProviderType.aws,
  String endpoint = 's3.us-east-1.amazonaws.com',
  String region = 'us-east-1',
  bool pathStyle = false,
}) => S3Account(
  id: 'test',
  name: 'test',
  provider: provider,
  endpoint: endpoint,
  region: region,
  accessKey: 'AKID',
  secretKey: 'SECRET',
  usePathStyle: pathStyle,
  useSSL: true,
);

void main() {
  group('S3Client.buildUri', () {
    test('virtual-hosted style for AWS', () {
      final c = S3Client(testAccount());
      final uri = c.buildUri(bucket: 'mybucket', key: 'a/b.jpg');
      expect(uri.host, 'mybucket.s3.us-east-1.amazonaws.com');
      expect(uri.path, '/a/b.jpg');
      c.close();
    });

    test('path-style for MinIO/custom', () {
      final c = S3Client(
        testAccount(
          provider: ProviderType.minio,
          endpoint: '192.168.1.10:9000',
          pathStyle: true,
        ),
      );
      final uri = c.buildUri(bucket: 'mybucket', key: 'a.jpg');
      expect(uri.host, '192.168.1.10');
      expect(uri.port, 9000);
      expect(uri.path, '/mybucket/a.jpg');
      c.close();
    });

    test('strips pasted scheme from endpoint', () {
      final c = S3Client(
        testAccount(
          provider: ProviderType.custom,
          endpoint: 'https://s3.example.com',
          pathStyle: true,
        ),
      );
      final uri = c.buildUri(bucket: 'b', key: 'k');
      expect(uri.host, 's3.example.com');
      expect(uri.path, '/b/k');
      c.close();
    });

    test('encodes keys but preserves slashes', () {
      final c = S3Client(testAccount(pathStyle: true));
      final uri = c.buildUri(bucket: 'b', key: 'my file/a+b.jpg');
      expect(uri.path, '/b/my%20file/a%2Bb.jpg');
      c.close();
    });
  });

  group('S3Client parsing', () {
    test('listBuckets parses XML', () async {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<ListAllMyBucketsResult>
  <Buckets>
    <Bucket><Name>b-bucket</Name><CreationDate>2024-01-01T00:00:00.000Z</CreationDate></Bucket>
    <Bucket><Name>a-bucket</Name><CreationDate>2024-02-01T00:00:00.000Z</CreationDate></Bucket>
  </Buckets>
</ListAllMyBucketsResult>''';
      final mock = MockClient((_) async => http.Response(xml, 200));
      final client = S3Client(testAccount(), mock);
      final buckets = await client.listBuckets();
      expect(buckets.map((b) => b.name), ['a-bucket', 'b-bucket']);
      client.close();
    });

    test(
      'listObjectsV2 parses prefixes + objects, hides dir placeholder',
      () async {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult>
  <IsTruncated>false</IsTruncated>
  <Prefix>photos/</Prefix>
  <CommonPrefixes><Prefix>photos/2024/</Prefix></CommonPrefixes>
  <Contents><Key>photos/</Key><Size>0</Size></Contents>
  <Contents><Key>photos/a.jpg</Key><Size>123</Size>
    <LastModified>2024-03-01T10:00:00.000Z</LastModified>
    <ETag>"abc"</ETag></Contents>
</ListBucketResult>''';
        final mock = MockClient((_) async => http.Response(xml, 200));
        final client = S3Client(testAccount(), mock);
        final result = await client.listObjectsV2('b', prefix: 'photos/');
        expect(result.prefixes, ['photos/2024/']);
        expect(result.objects.map((o) => o.key), ['photos/a.jpg']);
        expect(result.objects.first.size, 123);
        client.close();
      },
    );

    test('403 maps to access-denied message', () async {
      const xml =
          '<?xml version="1.0"?><Error><Code>AccessDenied</Code></Error>';
      final mock = MockClient((_) async => http.Response(xml, 403));
      final client = S3Client(testAccount(), mock);
      try {
        await client.listBuckets();
        fail('should throw');
      } catch (e) {
        expect('$e', contains('Access denied'));
      } finally {
        client.close();
      }
    });

    test('presignedGet contains signature', () {
      final client = S3Client(testAccount());
      final url = client.presignedGet('b', 'a.jpg', expiresSeconds: 600);
      expect(url.queryParameters['X-Amz-Signature'], hasLength(64));
      client.close();
    });
  });

  group('ProviderPresets', () {
    test('defaults are sane', () {
      expect(ProviderType.aws.defaultRegion, 'us-east-1');
      expect(ProviderType.cloudflareR2.defaultRegion, 'auto');
      expect(ProviderType.minio.defaultPathStyle, isTrue);
      expect(ProviderType.aws.defaultPathStyle, isFalse);
    });

    test('account json excludes secret', () {
      final a = testAccount();
      final json = a.toJson();
      expect(json.containsKey('secretKey'), isFalse);
      expect(json['accessKey'], 'AKID');
    });
  });
}
