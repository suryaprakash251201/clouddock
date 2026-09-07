// Stability regression tests: URI edges, error mapping, retry, atomic IO.

import 'dart:io';

import 'package:clouddock/src/core/s3/s3_account.dart';
import 'package:clouddock/src/core/s3/s3_client.dart';
import 'package:clouddock/src/core/s3/s3_exceptions.dart';
import 'package:clouddock/src/features/transfers/transfer_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

S3Account testAccount({
  String endpoint = 's3.us-east-1.amazonaws.com',
  String region = 'us-east-1',
  bool pathStyle = false,
  int? port,
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
  port: port,
);

void main() {
  group('buildUri edges', () {
    test('omits default https port from URI + host header', () {
      final c = S3Client(testAccount(endpoint: 's3.example.com:443'));
      final uri = c.buildUri(bucket: 'b', key: 'k');
      expect(uri.hasPort, isFalse);
      expect(uri.host, 'b.s3.example.com');
      c.close();
    });

    test('keeps custom port', () {
      final c = S3Client(
        testAccount(endpoint: 's3.example.com', pathStyle: true, port: 9000),
      );
      final uri = c.buildUri(bucket: 'b', key: 'k');
      expect(uri.port, 9000);
      expect(uri.path, '/b/k');
      c.close();
    });

    test('localhost forces path-style even when disabled', () {
      final c = S3Client(testAccount(endpoint: 'localhost:9000'));
      final uri = c.buildUri(bucket: 'b', key: 'k');
      expect(uri.host, 'localhost');
      expect(uri.path, '/b/k');
      c.close();
    });

    test('bracketed IPv6 with port parses', () {
      final c = S3Client(testAccount(endpoint: '[::1]:9000', pathStyle: true));
      final uri = c.buildUri(bucket: 'b', key: 'k');
      expect(uri.host, '::1');
      expect(uri.port, 9000);
      expect(uri.path, '/b/k');
      c.close();
    });

    test('strips scheme + path suffix from endpoint', () {
      final c = S3Client(
        testAccount(
          endpoint: 'https://s3.example.com/some/path',
          pathStyle: true,
        ),
      );
      final uri = c.buildUri(bucket: 'b', key: 'k');
      expect(uri.host, 's3.example.com');
      expect(uri.path, '/b/k');
      c.close();
    });

    test('explicit account.port wins over embedded port', () {
      final c = S3Client(
        testAccount(
          endpoint: 's3.example.com:8000',
          pathStyle: true,
          port: 9000,
        ),
      );
      expect(c.buildUri(bucket: 'b').port, 9000);
      c.close();
    });
  });

  group('S3Exception mapping', () {
    test('401 is auth failure, not retryable', () {
      final e = S3Exception.fromResponse(
        401,
        '<Error><Code>InvalidAccessKeyId</Code></Error>',
      );
      expect('$e', contains('Authentication failed'));
      expect(e.retryable, isFalse);
    });

    test('429/503 are retryable', () {
      expect(
        S3Exception.fromResponse(
          429,
          '<Error><Code>SlowDown</Code></Error>',
        ).retryable,
        isTrue,
      );
      expect(
        S3Exception.fromResponse(
          503,
          '<Error><Code>SlowDown</Code></Error>',
        ).retryable,
        isTrue,
      );
      expect(S3Exception.fromResponse(500, 'oops').retryable, isTrue);
    });

    test('NoSuchBucket gives actionable message', () {
      final e = S3Exception.fromResponse(
        404,
        '<Error><Code>NoSuchBucket</Code></Error>',
      );
      expect('$e', contains('Bucket not found'));
    });

    test('long bodies are truncated', () {
      final big = 'x' * 5000;
      final e = S3Exception.fromResponse(400, big);
      expect(e.message.length, lessThan(600));
    });

    test('network/timeout factories are retryable', () {
      expect(S3Exception.network('down').retryable, isTrue);
      expect(S3Exception.timeout('GET /').retryable, isTrue);
    });
  });

  group('S3Client resilience', () {
    test('malformed XML maps to MalformedResponse', () async {
      final mock = MockClient((_) async => http.Response('not xml <<<', 200));
      final client = S3Client(testAccount(), mock);
      try {
        await client.listBuckets();
        fail('should throw');
      } catch (e) {
        expect(e, isA<S3Exception>());
        expect((e as S3Exception).code, 'MalformedResponse');
      } finally {
        client.close();
      }
    });

    test('transient 503s are retried then succeed', () async {
      const xml = '''<?xml version="1.0"?>
<ListAllMyBucketsResult><Buckets>
<Bucket><Name>a</Name></Bucket>
</Buckets></ListAllMyBucketsResult>''';
      var calls = 0;
      final mock = MockClient((_) async {
        calls++;
        if (calls < 3) {
          return http.Response('<Error><Code>SlowDown</Code></Error>', 503);
        }
        return http.Response(xml, 200);
      });
      final client = S3Client(testAccount(), mock);
      final buckets = await client.listBuckets();
      expect(buckets.map((b) => b.name), ['a']);
      expect(calls, 3);
      client.close();
    });

    test('4xx is not retried', () async {
      var calls = 0;
      final mock = MockClient((_) async {
        calls++;
        return http.Response('<Error><Code>AccessDenied</Code></Error>', 403);
      });
      final client = S3Client(testAccount(), mock);
      try {
        await client.listBuckets();
        fail('should throw');
      } catch (_) {
        expect(calls, 1);
      } finally {
        client.close();
      }
    });

    test('headObject 404 returns null', () async {
      final mock = MockClient((_) async => http.Response('', 404));
      final client = S3Client(testAccount(), mock);
      expect(await client.headObject('b', 'missing.txt'), isNull);
      client.close();
    });

    test('downloadToFile is atomic and reports progress', () async {
      final bytes = List<int>.generate(1024, (i) => i % 256);
      final mock = MockClient((_) async => http.Response.bytes(bytes, 200));
      final client = S3Client(testAccount(), mock);
      final dir = await Directory.systemTemp.createTemp('clouddock_test');
      final savePath = '${dir.path}/sub/file.bin';
      final seen = <double>[];
      try {
        final f = await client.downloadToFile(
          'b',
          'file.bin',
          savePath,
          onProgress: seen.add,
        );
        expect(await f.exists(), isTrue);
        expect(await f.length(), 1024);
        expect(File('$savePath.part').existsSync(), isFalse);
        expect(seen, isNotEmpty);
        expect(seen.last, 1.0);
      } finally {
        client.close();
        await dir.delete(recursive: true);
      }
    });
  });

  group('TransferTask model', () {
    test('copyWith can clear errors on retry', () {
      const t = TransferTask(
        id: '1',
        type: TransferType.download,
        accountId: 'a',
        bucket: 'b',
        key: 'k',
        localPath: '/tmp/k',
        status: TransferStatus.failed,
        error: 'boom',
      );
      final retried = t.copyWith(
        status: TransferStatus.queued,
        progress: 0,
        clearError: true,
      );
      expect(retried.status, TransferStatus.queued);
      expect(retried.error, isNull);
    });
  });
}
