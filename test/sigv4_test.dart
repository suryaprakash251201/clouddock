// SigV4 unit tests anchored to AWS's documented example values where
// possible, plus internal consistency checks for presigning.

import 'package:clouddock/src/core/s3/sigv4.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SigV4', () {
    test('empty payload hash matches AWS constant', () {
      expect(
        SigV4.emptyHash,
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('sha256 of empty string', () {
      expect(SigV4.sha256Hex(''), SigV4.emptyHash);
    });

    test('sha256 of "abc" matches known vector', () {
      expect(
        SigV4.sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('RFC3986 encoding keeps unreserved, encodes space as %20', () {
      expect(SigV4.encodeRfc3986('abc-_.~123'), 'abc-_.~123');
      expect(SigV4.encodeRfc3986('a b+c'), 'a%20b%2Bc');
      expect(SigV4.encodeRfc3986('/a/b', encodeSlash: false), '/a/b');
      expect(SigV4.encodeRfc3986('/a/b', encodeSlash: true), '%2Fa%2Fb');
    });

    test('canonical query string is sorted and encoded', () {
      final qs = SigV4.canonicalQueryString({
        'prefix': 'photos/',
        'list-type': '2',
        'max-keys': '1000',
      });
      expect(qs, 'list-type=2&max-keys=1000&prefix=photos%2F');
    });

    test('canonical headers lowercases + sorts', () {
      final c = SigV4.canonicalizeHeaders({
        'Host': 'example.com',
        'X-Amz-Date': '20130524T000000Z',
      });
      expect(c.signedHeaders, 'host;x-amz-date');
      expect(
        c.canonicalHeaders,
        'host:example.com\nx-amz-date:20130524T000000Z\n',
      );
    });

    test('signing key matches AWS docs example (iam, us-east-1)', () {
      // AWS docs: secret "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      // date 20120215, region us-east-1, service iam.
      // Verified against Python hmac chain (ground truth).
      final key = SigV4.deriveSigningKey(
        'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
        '20120215',
        'us-east-1',
        'iam',
      );
      final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(
        hex,
        'f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d',
      );
    });

    test('presign produces all X-Amz query params + 64-hex signature', () {
      final uri = Uri.https(
        'mybucket.s3.us-east-1.amazonaws.com',
        '/photo.jpg',
      );
      final signed = SigV4.presign(
        accessKey: 'AKIAIOSFODNN7EXAMPLE',
        secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
        region: 'us-east-1',
        service: 's3',
        uri: uri,
        expiresSeconds: 3600,
        now: DateTime.utc(2013, 5, 24),
      );
      final q = signed.queryParameters;
      expect(q['X-Amz-Algorithm'], 'AWS4-HMAC-SHA256');
      expect(
        q['X-Amz-Credential'],
        contains('AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request'),
      );
      expect(q['X-Amz-Date'], '20130524T000000Z');
      expect(q['X-Amz-Expires'], '3600');
      expect(q['X-Amz-SignedHeaders'], 'host');
      expect(q['X-Amz-Signature'], hasLength(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(q['X-Amz-Signature']!), isTrue);
    });

    test('signHeaders output has Authorization with scope', () {
      final uri = Uri.https('s3.us-east-1.amazonaws.com', '/');
      final headers = SigV4.signHeaders(
        accessKey: 'AKID',
        secretKey: 'SECRET',
        region: 'us-east-1',
        service: 's3',
        method: 'GET',
        uri: uri,
        now: DateTime.utc(2024, 1, 2, 3, 4, 5),
      );
      expect(headers['x-amz-date'], '20240102T030405Z');
      expect(headers['authorization'], startsWith('AWS4-HMAC-SHA256 '));
      expect(headers['authorization'], contains('Credential=AKID/20240102/'));
    });
  });
}
