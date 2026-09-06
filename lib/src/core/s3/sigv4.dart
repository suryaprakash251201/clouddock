// AWS Signature Version 4 signer shared by all S3-compatible providers.
// Reference: https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html
//
// Handles header-based auth (regular requests) and query-based auth
// (presigned URLs). R2/MinIO/Wasabi/B2 all accept the same scheme with
// their own endpoint + region ("auto" for R2).

import 'dart:convert';

import 'package:crypto/crypto.dart';

class SigV4 {
  static const _emptyHash =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  /// SHA-256 hex of UTF-8 string.
  static String sha256Hex(String input) =>
      sha256.convert(utf8.encode(input)).toString();

  /// SHA-256 hex of bytes.
  static String sha256HexBytes(List<int> bytes) =>
      sha256.convert(bytes).toString();

  static List<int> _hmac(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  /// Derive signing key: kDate -> kRegion -> kService -> kSigning.
  static List<int> deriveSigningKey(
    String secretKey,
    String dateStamp,
    String region,
    String service,
  ) {
    final kSecret = utf8.encode('AWS4$secretKey');
    final kDate = _hmac(kSecret, dateStamp);
    final kRegion = _hmac(kDate, region);
    final kService = _hmac(kRegion, service);
    return _hmac(kService, 'aws4_request');
  }

  /// RFC 3986 percent-encoding for SigV4 (unreserved chars not encoded,
  /// spaces as %20 — never `+`).
  static String encodeRfc3986(String input, {bool encodeSlash = true}) {
    final out = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      if ((rune >= 0x41 && rune <= 0x5A) || // A-Z
          (rune >= 0x61 && rune <= 0x7A) || // a-z
          (rune >= 0x30 && rune <= 0x39) || // 0-9
          ch == '-' ||
          ch == '_' ||
          ch == '.' ||
          ch == '~' ||
          (!encodeSlash && ch == '/')) {
        out.write(ch);
      } else {
        for (final b in utf8.encode(ch)) {
          out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
        }
      }
    }
    return out.toString();
  }

  /// Canonical query string: keys sorted by encoded name.
  static String canonicalQueryString(Map<String, String> query) {
    final entries =
        query.entries
            .map(
              (e) => MapEntry(
                encodeRfc3986(e.key, encodeSlash: true),
                encodeRfc3986(e.value, encodeSlash: true),
              ),
            )
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    return entries.map((e) => '${e.key}=${e.value}').join('&');
  }

  /// Build canonical headers + signed-headers list. Header names lowercased,
  /// values trimmed + collapsed whitespace, names sorted.
  static ({String canonicalHeaders, String signedHeaders}) canonicalizeHeaders(
    Map<String, String> headers,
  ) {
    final normalized = <String, String>{};
    for (final e in headers.entries) {
      final name = e.key.toLowerCase().trim();
      final value = e.value.trim().replaceAll(RegExp(r'\s+'), ' ');
      normalized[name] = value;
    }
    final names = normalized.keys.toList()..sort();
    final canonical = names.map((n) => '$n:${normalized[n]}\n').join();
    return (canonicalHeaders: canonical, signedHeaders: names.join(';'));
  }

  /// Canonical URI: each path segment encoded, slashes preserved.
  /// Empty path becomes "/".
  static String canonicalUri(String path) {
    if (path.isEmpty) return '/';
    final withLeading = path.startsWith('/') ? path : '/$path';
    // Encode each segment but keep '/'.
    return encodeRfc3986(withLeading, encodeSlash: false)
    // encodeRfc3986 leaves '/' alone already; normalize double encoding guard:
    .replaceAll('%2F', '/');
  }

  /// Full canonical request string.
  static String buildCanonicalRequest({
    required String method,
    required String path,
    required Map<String, String> query,
    required Map<String, String> headers,
    required String payloadHash,
  }) {
    final c = canonicalizeHeaders(headers);
    return [
      method.toUpperCase(),
      canonicalUri(path),
      canonicalQueryString(query),
      c.canonicalHeaders,
      c.signedHeaders,
      payloadHash,
    ].join('\n');
  }

  /// String-to-sign for header auth.
  static String buildStringToSign({
    required String amzDate,
    required String credentialScope,
    required String canonicalRequest,
  }) {
    return [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      sha256Hex(canonicalRequest),
    ].join('\n');
  }

  static String _amzDate(DateTime t) =>
      '${_pad(t.yearUtc(), 4)}${_pad(t.month, 2)}${_pad(t.day, 2)}'
      'T${_pad(t.hour, 2)}${_pad(t.minute, 2)}${_pad(t.second, 2)}Z';

  static String _dateStamp(DateTime t) =>
      '${_pad(t.yearUtc(), 4)}${_pad(t.month, 2)}${_pad(t.day, 2)}';

  static String _pad(int v, int w) => v.toString().padLeft(w, '0');

  /// Extension to get UTC fields regardless of local/UTC DateTime.
  static String amzDateString(DateTime now) => _amzDate(now.toUtc());

  static String dateStampString(DateTime now) => _dateStamp(now.toUtc());

  /// Sign headers for a regular request. Returns headers to send, including
  /// Authorization, x-amz-date, x-amz-content-sha256 (+ session token).
  static Map<String, String> signHeaders({
    required String accessKey,
    required String secretKey,
    String? sessionToken,
    required String region,
    required String service,
    required String method,
    required Uri uri,
    Map<String, String> extraHeaders = const {},
    String payloadHash = _emptyHash,
    DateTime? now,
  }) {
    final t = (now ?? DateTime.now()).toUtc();
    final amzDate = amzDateString(t);
    final dateStamp = dateStampString(t);

    final headers = <String, String>{
      'host': uri.host + (uri.hasPort ? ':${uri.port}' : ''),
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash,
      ...extraHeaders,
    };
    if (sessionToken != null && sessionToken.isNotEmpty) {
      headers['x-amz-security-token'] = sessionToken;
    }

    final query = Map<String, String>.from(uri.queryParameters);
    final canonicalRequest = buildCanonicalRequest(
      method: method,
      path: uri.path,
      query: query,
      headers: headers,
      payloadHash: payloadHash,
    );
    final scope = '$dateStamp/$region/$service/aws4_request';
    final sts = buildStringToSign(
      amzDate: amzDate,
      credentialScope: scope,
      canonicalRequest: canonicalRequest,
    );
    final signingKey = deriveSigningKey(secretKey, dateStamp, region, service);
    final signature = Hmac(
      sha256,
      signingKey,
    ).convert(utf8.encode(sts)).toString();
    final signedHeaders = canonicalizeHeaders(headers).signedHeaders;

    return {
      ...headers,
      'authorization':
          'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, SignedHeaders=$signedHeaders, Signature=$signature',
    };
  }

  /// Presigned URL (query auth, GET by default). Returns full URI with
  /// X-Amz-* params + signature.
  static Uri presign({
    required String accessKey,
    required String secretKey,
    String? sessionToken,
    required String region,
    required String service,
    required Uri uri,
    required int expiresSeconds,
    DateTime? now,
  }) {
    final t = (now ?? DateTime.now()).toUtc();
    final amzDate = amzDateString(t);
    final dateStamp = dateStampString(t);
    final scope = '$dateStamp/$region/$service/aws4_request';

    final query = Map<String, String>.from(uri.queryParameters)
      ..['X-Amz-Algorithm'] = 'AWS4-HMAC-SHA256'
      ..['X-Amz-Credential'] = '$accessKey/$scope'
      ..['X-Amz-Date'] = amzDate
      ..['X-Amz-Expires'] = expiresSeconds.toString()
      ..['X-Amz-SignedHeaders'] = 'host';
    if (sessionToken != null && sessionToken.isNotEmpty) {
      query['X-Amz-Security-Token'] = sessionToken;
    }

    final headers = {'host': uri.host + (uri.hasPort ? ':${uri.port}' : '')};
    const payloadHash = 'UNSIGNED-PAYLOAD';
    final canonicalRequest = buildCanonicalRequest(
      method: 'GET',
      path: uri.path,
      query: query,
      headers: headers,
      payloadHash: payloadHash,
    );
    final sts = buildStringToSign(
      amzDate: amzDate,
      credentialScope: scope,
      canonicalRequest: canonicalRequest,
    );
    final signingKey = deriveSigningKey(secretKey, dateStamp, region, service);
    final signature = Hmac(
      sha256,
      signingKey,
    ).convert(utf8.encode(sts)).toString();
    query['X-Amz-Signature'] = signature;

    return uri.replace(queryParameters: query);
  }

  static String get emptyHash => _emptyHash;
}

extension _UtcYmd on DateTime {
  int yearUtc() => toUtc().year;
}
