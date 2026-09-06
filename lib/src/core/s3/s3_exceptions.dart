// Typed S3 errors with user-friendly messages.

class S3Exception implements Exception {
  final String message;
  final int? statusCode;
  final String? code;

  const S3Exception(this.message, {this.statusCode, this.code});

  @override
  String toString() => 'S3Exception($statusCode/$code): $message';

  /// Map HTTP status + S3 error code to actionable text.
  static S3Exception fromResponse(int status, String body) {
    final code = _extractCode(body);
    switch (status) {
      case 403:
        return S3Exception(
          'Access denied ($code). Check access key, secret, and bucket policy. '
          'On R2/B2 make sure the token has access to this bucket.',
          statusCode: status,
          code: code,
        );
      case 404:
        return S3Exception(
          'Not found ($code). The bucket or object does not exist.',
          statusCode: status,
          code: code,
        );
      case 400:
        if (code == 'AuthorizationHeaderMalformed' ||
            code == 'InvalidRequest') {
          return S3Exception(
            'Bad request ($code). Usually a wrong region or endpoint — '
            'verify the region matches the bucket (AWS/Wasabi/B2) or use "auto" (R2).',
            statusCode: status,
            code: code,
          );
        }
        return S3Exception(
          'Bad request ($code). $body',
          statusCode: status,
          code: code,
        );
      default:
        return S3Exception(
          'Request failed ($status/$code). $body',
          statusCode: status,
          code: code,
        );
    }
  }

  static String _extractCode(String body) {
    final match = RegExp(r'<Code>(.*?)</Code>', dotAll: true).firstMatch(body);
    return match?.group(1)?.trim() ?? 'Unknown';
  }
}
