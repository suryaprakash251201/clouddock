// Generic SigV4 S3 client for AWS S3, R2, MinIO, Wasabi, B2, and any
// S3-compatible endpoint. Injectable http.Client for tests.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 's3_account.dart';
import 's3_exceptions.dart';
import 's3_models.dart';
import 'sigv4.dart';

/// Timeouts and retry budget for all S3 calls.
const _requestTimeout = Duration(seconds: 30);
const _maxAttempts = 3;
const _baseBackoffMs = 500;
final _jitter = Random();

class S3Client {
  final S3Account account;
  final http.Client _http;
  static const _service = 's3';

  S3Client(this.account, [http.Client? httpClient])
    : _http = httpClient ?? http.Client();

  void close() => _http.close();

  // ---------- URI building ----------

  /// Build request URI honoring path-style vs virtual-hosted-style.
  /// Virtual-hosted: https://bucket.endpoint/key
  /// Path-style:     https://endpoint/bucket/key  (required for MinIO/R2/IP hosts)
  Uri buildUri({
    String? bucket,
    String? key,
    Map<String, String> query = const {},
  }) {
    final scheme = account.useSSL ? 'https' : 'http';
    final parsed = _parseEndpoint(account.endpoint, account.port);
    final hostname = parsed.host;
    var port = parsed.port;
    // Omit default ports so signing + Host header stay canonical.
    if ((scheme == 'https' && port == 443) ||
        (scheme == 'http' && port == 80)) {
      port = null;
    }

    final encodedKey = key == null || key.isEmpty ? '' : _encodeKey(key);

    if (bucket != null &&
        bucket.isNotEmpty &&
        !account.usePathStyle &&
        !_isIpOrLocal(hostname)) {
      // virtual-hosted
      return Uri(
        scheme: scheme,
        host: '$bucket.$hostname',
        port: port,
        path: '/$encodedKey',
        queryParameters: query.isEmpty ? null : query,
      ).normalizePath();
    }
    // path-style
    final path = bucket == null || bucket.isEmpty
        ? '/'
        : '/$bucket${encodedKey.isEmpty ? '' : '/$encodedKey'}';
    return Uri(
      scheme: scheme,
      host: hostname,
      port: port,
      path: path,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  /// Split user-supplied endpoint into host + port.
  /// Handles: "host", "host:9000", "https://host:9000/path",
  /// "[::1]", "[::1]:9000", "2600::1" (bare IPv6, no port).
  static ({String host, int? port}) _parseEndpoint(
    String endpoint,
    int? explicitPort,
  ) {
    var host = endpoint.trim();
    host = host.replaceFirst(RegExp(r'^https?://'), '');
    host = host.split('/').first.trim();
    if (host.isEmpty) return (host: host, port: explicitPort);

    // Bracketed IPv6: [::1] or [::1]:9000
    if (host.startsWith('[')) {
      final close = host.indexOf(']');
      if (close != -1) {
        final hostname = host.substring(0, close + 1);
        final rest = host.substring(close + 1);
        int? port = explicitPort;
        if (rest.startsWith(':')) {
          port ??= int.tryParse(rest.substring(1));
        }
        return (host: hostname, port: port);
      }
      return (host: host, port: explicitPort);
    }

    // Count colons: 0 = plain host, 1 = host:port candidate,
    // >1 = bare IPv6 without port.
    final colonCount = ':'.allMatches(host).length;
    if (colonCount == 1) {
      final idx = host.lastIndexOf(':');
      final maybePort = int.tryParse(host.substring(idx + 1));
      if (maybePort != null) {
        return (host: host.substring(0, idx), port: explicitPort ?? maybePort);
      }
    }
    return (host: host, port: explicitPort);
  }

  static bool _isIpOrLocal(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost') return true;
    if (RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(h)) return true;
    // IPv6 (bracketed or bare) contains multiple colons.
    if (h.contains(':')) return true;
    return false;
  }

  /// Encode S3 key preserving '/' separators.
  static String _encodeKey(String key) => key
      .split('/')
      .map((s) => SigV4.encodeRfc3986(s, encodeSlash: true))
      .join('/');

  // ---------- retry + transport ----------

  static bool _isRetryable(Object e) {
    if (e is SocketException || e is TimeoutException || e is HttpException) {
      return true;
    }
    if (e is S3Exception) return e.retryable;
    return false;
  }

  Future<T> _withRetry<T>(String op, Future<T> Function() fn) async {
    Object last = StateError('unreachable');
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        return await fn().timeout(_requestTimeout);
      } on TimeoutException {
        last = S3Exception.timeout(op);
      } on SocketException catch (e) {
        last = S3Exception.network(
          e.message.isEmpty ? e.toString() : e.message,
        );
      } on HttpException catch (e) {
        last = S3Exception.network(e.message);
      } on http.ClientException catch (e) {
        last = S3Exception.network(e.message);
      } catch (e) {
        last = e;
      }
      if (attempt == _maxAttempts || !_isRetryable(last)) {
        if (last is Exception) throw last;
        throw Exception('$last');
      }
      final backoff =
          _baseBackoffMs * (1 << (attempt - 1)) + _jitter.nextInt(250);
      await Future.delayed(Duration(milliseconds: backoff));
    }
    // Unreachable.
    throw last is Exception ? last : Exception('$last');
  }

  XmlDocument _parseXml(String body, String op) {
    try {
      return XmlDocument.parse(body);
    } catch (e) {
      throw S3Exception.malformed('$op: ${e.toString().split('\n').first}');
    }
  }

  // ---------- low-level signed call ----------

  Future<http.Response> _signed(
    String method,
    Uri uri, {
    Map<String, String> extraHeaders = const {},
    List<int>? body,
    String? payloadHash,
  }) async {
    final hash =
        payloadHash ??
        (body == null ? SigV4.emptyHash : SigV4.sha256HexBytes(body));
    Map<String, String> sign() => SigV4.signHeaders(
      accessKey: account.accessKey,
      secretKey: account.secretKey,
      sessionToken: account.sessionToken,
      region: account.region,
      service: _service,
      method: method,
      uri: uri,
      extraHeaders: {
        ...extraHeaders,
        if (body != null) 'content-length': '${body.length}',
      },
      payloadHash: hash,
    );
    return _withRetry('$method ${uri.path}', () async {
      http.StreamedResponse streamed;
      try {
        // Rebuild + re-sign per attempt: http.Request is single-use and
        // x-amz-date should stay fresh across backoff delays.
        final req = http.Request(method, uri)..headers.addAll(sign());
        if (body != null) req.bodyBytes = body;
        streamed = await _http.send(req);
      } on http.ClientException catch (e) {
        throw S3Exception.network(e.message);
      }
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode >= 400) {
        throw S3Exception.fromResponse(resp.statusCode, resp.body);
      }
      return resp;
    });
  }

  Future<http.StreamedResponse> _signedStream(
    String method,
    Uri uri, {
    Map<String, String> extraHeaders = const {},
    Stream<List<int>>? body,
    int? contentLength,
    String payloadHash = 'UNSIGNED-PAYLOAD',
  }) async {
    final signed = SigV4.signHeaders(
      accessKey: account.accessKey,
      secretKey: account.secretKey,
      sessionToken: account.sessionToken,
      region: account.region,
      service: _service,
      method: method,
      uri: uri,
      extraHeaders: {
        ...extraHeaders,
        if (contentLength != null) 'content-length': '$contentLength',
      },
      payloadHash: payloadHash,
    );
    http.BaseRequest buildRequest() {
      if (body == null) {
        return http.Request(method, uri)..headers.addAll(signed);
      }
      final streamedReq = http.StreamedRequest(method, uri)
        ..headers.addAll(signed);
      if (contentLength != null) {
        streamedReq.contentLength = contentLength;
      }
      // Forward the byte stream without buffering the whole file in memory.
      body.listen(
        streamedReq.sink.add,
        onDone: () => streamedReq.sink.close(),
        onError: (Object e, StackTrace st) => streamedReq.sink.close(),
        cancelOnError: true,
      );
      return streamedReq;
    }

    // Note: streaming bodies are not retried mid-stream (non-idempotent
    // single-shot streams). Retries apply to connection setup failures
    // surfaced as S3Exception.network/timeout by the caller.
    try {
      final streamed = await _http
          .send(buildRequest())
          .timeout(_requestTimeout);
      if (streamed.statusCode >= 400) {
        final text = await streamed.stream.bytesToString().timeout(
          const Duration(seconds: 10),
        );
        throw S3Exception.fromResponse(streamed.statusCode, text);
      }
      return streamed;
    } on TimeoutException {
      throw S3Exception.timeout('$method ${uri.path}');
    } on SocketException catch (e) {
      throw S3Exception.network(e.message.isEmpty ? e.toString() : e.message);
    } on HttpException catch (e) {
      throw S3Exception.network(e.message);
    } on http.ClientException catch (e) {
      throw S3Exception.network(e.message);
    }
  }

  // ---------- buckets ----------

  Future<List<S3Bucket>> listBuckets() async {
    final uri = buildUri();
    final resp = await _signed('GET', uri);
    final doc = _parseXml(resp.body, 'ListBuckets');
    return doc
        .findAllElements('Bucket')
        .map((e) {
          final name = e.getElement('Name')?.innerText ?? '';
          final dateStr = e.getElement('CreationDate')?.innerText;
          return S3Bucket(
            name: name,
            creationDate: dateStr == null ? null : DateTime.tryParse(dateStr),
          );
        })
        .where((b) => b.name.isNotEmpty)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> createBucket(String bucket) async {
    final uri = buildUri(bucket: bucket);
    // us-east-1 needs no LocationConstraint on AWS; other regions and most
    // S3 clones accept/ignore it. R2 ignores it entirely.
    List<int>? body;
    final headers = <String, String>{};
    if (account.region != 'us-east-1' && account.region != 'auto') {
      final xmlBody =
          '<CreateBucketConfiguration><LocationConstraint>${account.region}</LocationConstraint></CreateBucketConfiguration>';
      body = utf8.encode(xmlBody);
      headers['content-type'] = 'application/xml';
    }
    await _signed('PUT', uri, extraHeaders: headers, body: body);
  }

  Future<void> deleteBucket(String bucket) async {
    await _signed('DELETE', buildUri(bucket: bucket));
  }

  /// HEAD bucket as a cheap connectivity check.
  Future<bool> headBucket(String bucket) async {
    try {
      await _signed('HEAD', buildUri(bucket: bucket));
      return true;
    } on S3Exception catch (e) {
      if (e.statusCode == 404) return false;
      rethrow;
    }
  }

  /// HEAD object to fetch size / etag without downloading the body.
  /// Returns null when the object does not exist.
  Future<S3Object?> headObject(String bucket, String key) async {
    try {
      final uri = buildUri(bucket: bucket, key: key);
      final hash = SigV4.emptyHash;
      Map<String, String> sign() => SigV4.signHeaders(
        accessKey: account.accessKey,
        secretKey: account.secretKey,
        sessionToken: account.sessionToken,
        region: account.region,
        service: _service,
        method: 'HEAD',
        uri: uri,
        payloadHash: hash,
      );
      final streamed = await _withRetry('HEAD $key', () async {
        try {
          final req = http.Request('HEAD', uri)..headers.addAll(sign());
          return await _http.send(req);
        } on http.ClientException catch (e) {
          throw S3Exception.network(e.message);
        }
      });
      await streamed.stream.drain();
      if (streamed.statusCode == 404) return null;
      if (streamed.statusCode >= 400) {
        throw S3Exception.fromResponse(streamed.statusCode, 'HEAD $key');
      }
      final length =
          int.tryParse(streamed.headers['content-length'] ?? '') ?? 0;
      final etag = streamed.headers['etag']?.replaceAll('"', '');
      return S3Object(key: key, size: length, etag: etag);
    } on S3Exception catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  // ---------- objects ----------

  Future<ListObjectsResult> listObjectsV2(
    String bucket, {
    String prefix = '',
    String delimiter = '/',
    String? continuationToken,
    int maxKeys = 1000,
  }) async {
    final query = <String, String>{
      'list-type': '2',
      'prefix': prefix,
      'delimiter': delimiter,
      'max-keys': '$maxKeys',
      'continuation-token': ?continuationToken,
    };
    final resp = await _signed('GET', buildUri(bucket: bucket, query: query));
    final doc = _parseXml(resp.body, 'ListObjectsV2');

    String? text(String tag) {
      final els = doc.findAllElements(tag);
      return els.isEmpty ? null : els.first.innerText;
    }

    final isTruncated =
        (text('IsTruncated') ?? 'false').toLowerCase() == 'true';
    final nextToken = text('NextContinuationToken');
    final prefixes = doc
        .findAllElements('CommonPrefixes')
        .map((e) => e.getElement('Prefix')?.innerText ?? '')
        .where((p) => p.isNotEmpty)
        .toList();
    final objects = doc
        .findAllElements('Contents')
        .map((e) {
          final key = e.getElement('Key')?.innerText ?? '';
          final size =
              int.tryParse(e.getElement('Size')?.innerText ?? '0') ?? 0;
          final lm = DateTime.tryParse(
            e.getElement('LastModified')?.innerText ?? '',
          );
          final etag = e.getElement('ETag')?.innerText.replaceAll('"', '');
          final storageClass = e.getElement('StorageClass')?.innerText;
          return S3Object(
            key: key,
            size: size,
            lastModified: lm,
            etag: etag,
            storageClass: storageClass,
          );
        })
        .where((o) {
          // Hide the current-dir placeholder from file rows (keep prefixes).
          if (o.key == prefix) return false;
          return o.key.isNotEmpty;
        })
        .toList();

    return ListObjectsResult(
      prefixes: prefixes,
      objects: objects,
      isTruncated: isTruncated,
      nextContinuationToken: nextToken,
      prefix: prefix,
    ).sorted();
  }

  /// Fetch all pages (careful with huge buckets; callers paginate for >5k).
  Future<ListObjectsResult> listAllObjects(
    String bucket, {
    String prefix = '',
    String delimiter = '/',
  }) async {
    final allPrefixes = <String>[];
    final allObjects = <S3Object>[];
    String? token;
    do {
      final page = await listObjectsV2(
        bucket,
        prefix: prefix,
        delimiter: delimiter,
        continuationToken: token,
      );
      allPrefixes.addAll(page.prefixes);
      allObjects.addAll(page.objects);
      token = page.isTruncated ? page.nextContinuationToken : null;
    } while (token != null);
    return ListObjectsResult(
      prefixes: allPrefixes..sort(),
      objects: allObjects,
      isTruncated: false,
      prefix: prefix,
    );
  }

  Future<void> putObject(
    String bucket,
    String key,
    List<int> bytes, {
    String? contentType,
  }) async {
    await _signedStream(
      'PUT',
      buildUri(bucket: bucket, key: key),
      extraHeaders: {'content-type': ?contentType},
      body: Stream.value(bytes),
      contentLength: bytes.length,
      payloadHash: SigV4.sha256HexBytes(bytes),
    ).then((r) => r.stream.drain());
  }

  /// Stream download; caller pipes [stream] to a file.
  Future<http.StreamedResponse> getObject(String bucket, String key) {
    return _signedStream('GET', buildUri(bucket: bucket, key: key));
  }

  /// Download to [savePath] atomically (`.part` + rename) with optional
  /// progress callback (0..1). Cleans up the temp file on failure.
  Future<File> downloadToFile(
    String bucket,
    String key,
    String savePath, {
    void Function(double progress)? onProgress,
  }) async {
    final stream = await getObject(bucket, key);
    final total = stream.contentLength ?? -1;
    final file = File(savePath);
    await file.parent.create(recursive: true);
    final tmp = File('$savePath.part');
    // Remove any stale temp file from a previous interrupted download.
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {
      // best effort
    }
    final sink = tmp.openWrite();
    var received = 0;
    try {
      await for (final chunk in stream.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null && total > 0) {
          onProgress(received / total);
        }
      }
      await sink.close();
      await tmp.rename(savePath);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    onProgress?.call(1.0);
    return file;
  }

  Future<void> deleteObject(String bucket, String key) async {
    await _signed('DELETE', buildUri(bucket: bucket, key: key));
  }

  Future<void> deleteObjects(String bucket, List<String> keys) async {
    if (keys.isEmpty) return;
    // Multi-object delete; fall back to sequential on providers that reject it.
    final xmlBody =
        '<Delete><Quiet>true</Quiet>'
        '${keys.map((k) => '<Object><Key>${_xmlEscape(k)}</Key></Object>').join()}'
        '</Delete>';
    final body = utf8.encode(xmlBody);
    try {
      await _signed(
        'POST',
        buildUri(bucket: bucket, query: {'delete': ''}),
        extraHeaders: {
          'content-type': 'application/xml',
          'content-md5': base64.encode(md5(body)),
        },
        body: body,
      );
    } on S3Exception catch (e) {
      if (e.statusCode == 400 || e.statusCode == 501) {
        for (final k in keys) {
          await deleteObject(bucket, k);
        }
        return;
      }
      rethrow;
    }
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// MD5 bytes (for the ?delete Content-MD5 header).
  static List<int> md5(List<int> bytes) => crypto.md5.convert(bytes).bytes;

  Future<void> copyObject(String bucket, String fromKey, String toKey) async {
    // CopySource must be URL-encoded but keep slashes.
    final source = '/$bucket/${_encodeKey(fromKey)}';
    await _signed(
      'PUT',
      buildUri(bucket: bucket, key: toKey),
      extraHeaders: {'x-amz-copy-source': source},
    );
  }

  Future<void> moveObject(String bucket, String fromKey, String toKey) async {
    await copyObject(bucket, fromKey, toKey);
    await deleteObject(bucket, fromKey);
  }

  /// Create 0-byte "folder" placeholder so empty prefixes show up.
  Future<void> createFolder(String bucket, String prefix) async {
    final key = prefix.endsWith('/') ? prefix : '$prefix/';
    await putObject(
      bucket,
      key,
      Uint8List(0),
      contentType: 'application/x-directory',
    );
  }

  // ---------- multipart (files > 8 MB) ----------

  Future<String> createMultipartUpload(
    String bucket,
    String key, {
    String? contentType,
  }) async {
    final resp = await _signed(
      'POST',
      buildUri(bucket: bucket, key: key, query: {'uploads': ''}),
      extraHeaders: {'content-type': ?contentType},
    );
    final doc = _parseXml(resp.body, 'CreateMultipartUpload');
    final id = doc.findAllElements('UploadId').firstOrNull?.innerText;
    if (id == null || id.isEmpty) {
      throw const S3Exception('No UploadId in CreateMultipartUpload response');
    }
    return id;
  }

  /// Upload one part; returns ETag (caller strips quotes when completing).
  Future<String> uploadPart(
    String bucket,
    String key,
    String uploadId,
    int partNumber,
    Stream<List<int>> data,
    int length,
  ) async {
    final resp = await _signedStream(
      'PUT',
      buildUri(
        bucket: bucket,
        key: key,
        query: {'partNumber': '$partNumber', 'uploadId': uploadId},
      ),
      body: data,
      contentLength: length,
    );
    await resp.stream.drain();
    final etag = resp.headers['etag'] ?? '';
    if (etag.isEmpty) throw const S3Exception('Missing ETag on UploadPart');
    return etag;
  }

  Future<void> completeMultipartUpload(
    String bucket,
    String key,
    String uploadId,
    List<CompletedPart> parts,
  ) async {
    final sorted = List<CompletedPart>.of(parts)
      ..sort((a, b) => a.partNumber.compareTo(b.partNumber));
    final xmlBody =
        '<CompleteMultipartUpload>'
        '${sorted.map((p) => '<Part><PartNumber>${p.partNumber}</PartNumber><ETag>${p.etag}</ETag></Part>').join()}'
        '</CompleteMultipartUpload>';
    await _signed(
      'POST',
      buildUri(bucket: bucket, key: key, query: {'uploadId': uploadId}),
      extraHeaders: {'content-type': 'application/xml'},
      body: utf8.encode(xmlBody),
    );
  }

  Future<void> abortMultipartUpload(
    String bucket,
    String key,
    String uploadId,
  ) async {
    await _signed(
      'DELETE',
      buildUri(bucket: bucket, key: key, query: {'uploadId': uploadId}),
    );
  }

  // ---------- sharing ----------

  /// Presigned GET URL valid for [expiresSeconds] (max 604800).
  Uri presignedGet(
    String bucket,
    String key, {
    int expiresSeconds = 3600,
    DateTime? now,
  }) {
    final uri = buildUri(bucket: bucket, key: key);
    return SigV4.presign(
      accessKey: account.accessKey,
      secretKey: account.secretKey,
      sessionToken: account.sessionToken,
      region: account.region,
      service: _service,
      uri: uri,
      expiresSeconds: expiresSeconds.clamp(1, 604800),
      now: now,
    );
  }
}
