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

/// Full object metadata from HEAD (size, type, etag, custom metadata…).
class S3ObjectDetails {
  final String key;
  final int size;
  final String? etag;
  final String? contentType;
  final DateTime? lastModified;
  final String? storageClass;
  final String? versionId;
  final String? cacheControl;
  final String? contentDisposition;
  final String? contentEncoding;

  /// User metadata (x-amz-meta-*), keys keep the prefix stripped.
  final Map<String, String> metadata;

  const S3ObjectDetails({
    required this.key,
    required this.size,
    this.etag,
    this.contentType,
    this.lastModified,
    this.storageClass,
    this.versionId,
    this.cacheControl,
    this.contentDisposition,
    this.contentEncoding,
    this.metadata = const {},
  });

  bool get hasMetadata => metadata.isNotEmpty;
}

/// One entry from ListObjectVersions (a version or a delete marker).
class S3ObjectVersion {
  final String key;
  final String versionId;
  final bool isLatest;
  final bool isDeleteMarker;
  final int size;
  final DateTime? lastModified;
  final String? etag;
  final String? storageClass;
  final String? owner;

  const S3ObjectVersion({
    required this.key,
    required this.versionId,
    this.isLatest = false,
    this.isDeleteMarker = false,
    this.size = 0,
    this.lastModified,
    this.etag,
    this.storageClass,
    this.owner,
  });

  /// Delete markers have no data to read/restore.
  bool get isRestorable => !isDeleteMarker;

  String get shortVersionId =>
      versionId.length <= 10 ? versionId : versionId.substring(0, 10);
}

/// Result of ListObjectVersions, optionally paginated.
class ListObjectVersionsResult {
  final List<S3ObjectVersion> versions;
  final bool isTruncated;
  final String? nextKeyMarker;
  final String? nextVersionIdMarker;

  const ListObjectVersionsResult({
    required this.versions,
    this.isTruncated = false,
    this.nextKeyMarker,
    this.nextVersionIdMarker,
  });
}

/// Object tag (key/value pair).
class S3ObjectTag {
  final String key;
  final String value;
  const S3ObjectTag(this.key, this.value);

  @override
  bool operator ==(Object other) =>
      other is S3ObjectTag && other.key == key && other.value == value;

  @override
  int get hashCode => Object.hash(key, value);
}

/// Bucket versioning state (`getBucketVersioning`).
enum BucketVersioning { unversioned, enabled, suspended, unknown }
