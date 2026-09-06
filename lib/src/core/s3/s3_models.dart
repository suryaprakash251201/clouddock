// Shared S3 value objects: buckets, objects, list results.

class S3Bucket {
  final String name;
  final DateTime? creationDate;

  const S3Bucket({required this.name, this.creationDate});
}

class S3Object {
  final String key;
  final int size;
  final DateTime? lastModified;
  final String? etag;
  final String? storageClass;

  const S3Object({
    required this.key,
    required this.size,
    this.lastModified,
    this.etag,
    this.storageClass,
  });

  /// File name without prefix.
  String get name {
    final trimmed = key.endsWith('/') ? key.substring(0, key.length - 1) : key;
    final idx = trimmed.lastIndexOf('/');
    return idx == -1 ? trimmed : trimmed.substring(idx + 1);
  }

  bool get isFolderPlaceholder => key.endsWith('/') && size == 0;

  String get extension {
    final n = name;
    final idx = n.lastIndexOf('.');
    return idx == -1 ? '' : n.substring(idx + 1).toLowerCase();
  }
}

/// Result of ListObjectsV2 with delimiter='/': [prefixes] are virtual
/// folders, [objects] are files (plus the current dir placeholder).
class ListObjectsResult {
  final List<String> prefixes;
  final List<S3Object> objects;
  final bool isTruncated;
  final String? nextContinuationToken;
  final String? prefix;

  const ListObjectsResult({
    required this.prefixes,
    required this.objects,
    required this.isTruncated,
    this.nextContinuationToken,
    this.prefix,
  });

  /// Folders first, then files sorted by name.
  ListObjectsResult sorted() {
    final p = List<String>.of(prefixes)..sort();
    final o = List<S3Object>.of(objects)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return ListObjectsResult(
      prefixes: p,
      objects: o,
      isTruncated: isTruncated,
      nextContinuationToken: nextContinuationToken,
      prefix: prefix,
    );
  }
}

class MultipartInit {
  final String uploadId;
  const MultipartInit(this.uploadId);
}

class CompletedPart {
  final int partNumber;
  final String etag;
  const CompletedPart(this.partNumber, this.etag);
}
