// Typed S3 errors with user-friendly messages.

class S3Exception implements Exception {
  final String message;
  final int? statusCode;
  final String? code;
  final bool retryable;

  const S3Exception(
    this.message, {
    this.statusCode,
    this.code,
    this.retryable = false,
  });

  factory S3Exception.network(String details) => S3Exception(
    'Network error: $details. Check your connection and endpoint.',
    code: 'NetworkError',
    retryable: true,
  );

  factory S3Exception.timeout(String op) => S3Exception(
    '$op timed out. Check your connection or try again.',
    code: 'Timeout',
    retryable: true,
  );

  factory S3Exception.malformed(String details) => S3Exception(
    'Unexpected server response ($details). The endpoint may not be S3-compatible.',
    code: 'MalformedResponse',
  );

  @override
  String toString() => 'S3Exception($statusCode/$code): $message';

  /// Map HTTP status + S3 error code to actionable text.
  static S3Exception fromResponse(int status, String body) {
    final code = _extractCode(body);
    final truncated = body.length > 500 ? '${body.substring(0, 500)}…' : body;
    switch (status) {
      case 401:
        return S3Exception(
          'Authentication failed ($code). Check access key and secret.',
          statusCode: status,
          code: code,
        );
      case 403:
        return S3Exception(
          'Access denied ($code). Check access key, secret, and bucket policy. '
          'On R2/B2 make sure the token has access to this bucket.',
          statusCode: status,
          code: code,
        );
      case 404:
        if (code == 'NoSuchBucket') {
          return S3Exception(
            'Bucket not found. It may have been deleted or the region/endpoint is wrong.',
            statusCode: status,
            code: code,
          );
        }
        if (code == 'NoSuchKey' || code == 'NoSuchObject') {
          return S3Exception(
            'Object not found. It may have been deleted or renamed.',
            statusCode: status,
            code: code,
          );
        }
        return S3Exception(
          'Not found ($code). The bucket or object does not exist.',
          statusCode: status,
          code: code,
        );
      case 400:
        if (code == 'AuthorizationHeaderMalformed' ||
            code == 'InvalidRequest' ||
            code == 'InvalidRegion' ||
            code == 'SignatureDoesNotMatch') {
          return S3Exception(
            'Bad request ($code). Usually a wrong region or endpoint — '
            'verify the region matches the bucket (AWS/Wasabi/B2) or use "auto" (R2).',
            statusCode: status,
            code: code,
          );
        }
        return S3Exception(
          'Bad request ($code). $truncated',
          statusCode: status,
          code: code,
        );
      case 429:
      case 503:
        return S3Exception(
          'Server is throttling requests ($status/$code). Retrying may help.',
          statusCode: status,
          code: code,
          retryable: true,
        );
      case 500:
      case 502:
      case 504:
        return S3Exception(
          'Server error ($status/$code). Please retry.',
          statusCode: status,
          code: code,
          retryable: true,
        );
      default:
        return S3Exception(
          'Request failed ($status/$code). $truncated',
          statusCode: status,
          code: code,
          retryable: status >= 500,
        );
    }
  }

  static String _extractCode(String body) {
    final match = RegExp(r'<Code>(.*?)</Code>', dotAll: true).firstMatch(body);
    return match?.group(1)?.trim() ?? 'Unknown';
  }
}
