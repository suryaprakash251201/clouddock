// Generic SigV4 S3 client for AWS S3, R2, MinIO, Wasabi, B2, and any
// S3-compatible endpoint. Injectable http.Client for tests.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 's3_account.dart';
import 's3_exceptions.dart';
import 's3_models.dart';
import 'sigv4.dart';

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
    var host = account.endpoint.trim();
    // Strip any scheme the user pasted.
    host = host.replaceFirst(RegExp(r'^https?://'), '');
    // Split host:port if embedded.
    String hostname = host;
    int? port = account.port;
    if (host.contains(':')) {
      final parts = host.split(':');
      if (parts.length == 2) {
        hostname = parts[0];
        port ??= int.tryParse(parts[1].split('/').first);
      }
    }
    hostname = hostname.split('/').first;

    final encodedKey = key == null || key.isEmpty ? '' : _encodeKey(key);

    if (bucket != null &&
        bucket.isNotEmpty &&
        !account.usePathStyle &&
        !_isIp(hostname)) {
      // virtual-hosted
      return Uri(
        scheme: scheme,
        host: '$bucket.$hostname',
        port: port ?? 0,
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
      port: port ?? 0,
      path: path,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  static bool _isIp(String host) =>
      RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(host) || host.contains(':');

  /// Encode S3 key preserving '/' separators.
  static String _encodeKey(String key) => key
      .split('/')
      .map((s) => SigV4.encodeRfc3986(s, encodeSlash: true))
      .join('/');

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
        if (body != null) 'content-length': '${body.length}',
      },
      payloadHash: hash,
    );
    final req = http.Request(method, uri)..headers.addAll(signed);
    if (body != null) req.bodyBytes = body;
    final streamed = await _http.send(req);
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode >= 400) {
      throw S3Exception.fromResponse(resp.statusCode, resp.body);
    }
    return resp;
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
    final req = http.Request(method, uri)..headers.addAll(signed);
    http.BaseRequest toSend = req;
    if (body != null) {
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
      toSend = streamedReq;
    }
    final streamed = await _http.send(toSend);
    if (streamed.statusCode >= 400) {
      final text = await streamed.stream.bytesToString();
      throw S3Exception.fromResponse(streamed.statusCode, text);
    }
    return streamed;
  }

  // ---------- buckets ----------

  Future<List<S3Bucket>> listBuckets() async {
    final uri = buildUri();
    final resp = await _signed('GET', uri);
    final doc = XmlDocument.parse(resp.body);
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
      if (continuationToken != null) 'continuation-token': continuationToken,
    };
    final resp = await _signed('GET', buildUri(bucket: bucket, query: query));
    final doc = XmlDocument.parse(resp.body);

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
      extraHeaders: {if (contentType != null) 'content-type': contentType},
      body: Stream.value(bytes),
      contentLength: bytes.length,
      payloadHash: SigV4.sha256HexBytes(bytes),
    ).then((r) => r.stream.drain());
  }

  /// Stream download; caller pipes [stream] to a file.
  Future<http.StreamedResponse> getObject(String bucket, String key) {
    return _signedStream('GET', buildUri(bucket: bucket, key: key));
  }

  /// Download to [savePath] with optional progress callback (0..1, -1 if unknown).
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
    final sink = file.openWrite();
    var received = 0;
    await for (final chunk in stream.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (onProgress != null && total > 0) {
        onProgress(received / total);
      }
    }
    await sink.close();
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
      extraHeaders: {if (contentType != null) 'content-type': contentType},
    );
    final doc = XmlDocument.parse(resp.body);
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
