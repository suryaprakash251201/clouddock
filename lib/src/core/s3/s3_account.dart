// S3 account model + provider presets.
// Supports AWS S3, Cloudflare R2, MinIO, Wasabi, Backblaze B2, and custom
// S3-compatible endpoints with a single generic profile.

/// Supported provider types. All use SigV4; differences are endpoint
/// format, default region, and path-style vs virtual-hosted defaults.
enum ProviderType { aws, cloudflareR2, minio, wasabi, backblazeB2, custom }

extension ProviderTypeX on ProviderType {
  String get label {
    switch (this) {
      case ProviderType.aws:
        return 'AWS S3';
      case ProviderType.cloudflareR2:
        return 'Cloudflare R2';
      case ProviderType.minio:
        return 'MinIO';
      case ProviderType.wasabi:
        return 'Wasabi';
      case ProviderType.backblazeB2:
        return 'Backblaze B2';
      case ProviderType.custom:
        return 'Custom S3-compatible';
    }
  }

  /// Providers that effectively require path-style addressing.
  bool get defaultPathStyle {
    switch (this) {
      case ProviderType.cloudflareR2:
      case ProviderType.minio:
        return true;
      case ProviderType.aws:
      case ProviderType.wasabi:
      case ProviderType.backblazeB2:
      case ProviderType.custom:
        return false;
    }
  }

  String get defaultRegion {
    switch (this) {
      case ProviderType.aws:
        return 'us-east-1';
      case ProviderType.cloudflareR2:
        return 'auto';
      case ProviderType.minio:
        return 'us-east-1';
      case ProviderType.wasabi:
        return 'us-east-1';
      case ProviderType.backblazeB2:
        return 'us-west-002';
      case ProviderType.custom:
        return 'us-east-1';
    }
  }
}

/// One stored connection profile. Secrets (secretKey/sessionToken) are
/// NEVER serialized via [toJson]; they live in secure storage only.
class S3Account {
  final String id;
  final String name;
  final ProviderType provider;
  final String
  endpoint; // host or host:port, no scheme (e.g. s3.us-east-1.amazonaws.com)
  final String region;
  final String accessKey;
  final String secretKey;
  final String? sessionToken;
  final bool usePathStyle;
  final bool useSSL;
  final int? port;

  const S3Account({
    required this.id,
    required this.name,
    required this.provider,
    required this.endpoint,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    this.sessionToken,
    required this.usePathStyle,
    required this.useSSL,
    this.port,
  });

  /// Public metadata only (for SharedPreferences). Secrets excluded.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'provider': provider.name,
    'endpoint': endpoint,
    'region': region,
    'accessKey': accessKey,
    'usePathStyle': usePathStyle,
    'useSSL': useSSL,
    'port': port,
    'hasSessionToken': sessionToken != null && sessionToken!.isNotEmpty,
  };

  static S3Account fromJson(
    Map<String, dynamic> json, {
    required String secretKey,
    String? sessionToken,
  }) {
    return S3Account(
      id: json['id'] as String,
      name: json['name'] as String,
      provider: ProviderType.values.firstWhere(
        (e) => e.name == json['provider'],
        orElse: () => ProviderType.custom,
      ),
      endpoint: json['endpoint'] as String? ?? '',
      region: json['region'] as String? ?? 'us-east-1',
      accessKey: json['accessKey'] as String? ?? '',
      secretKey: secretKey,
      sessionToken: sessionToken,
      usePathStyle: json['usePathStyle'] as bool? ?? false,
      useSSL: json['useSSL'] as bool? ?? true,
      port: json['port'] as int?,
    );
  }

  S3Account copyWith({
    String? name,
    ProviderType? provider,
    String? endpoint,
    String? region,
    String? accessKey,
    String? secretKey,
    String? sessionToken,
    bool? usePathStyle,
    bool? useSSL,
    int? port,
  }) {
    return S3Account(
      id: id,
      name: name ?? this.name,
      provider: provider ?? this.provider,
      endpoint: endpoint ?? this.endpoint,
      region: region ?? this.region,
      accessKey: accessKey ?? this.accessKey,
      secretKey: secretKey ?? this.secretKey,
      sessionToken: sessionToken ?? this.sessionToken,
      usePathStyle: usePathStyle ?? this.usePathStyle,
      useSSL: useSSL ?? this.useSSL,
      port: port ?? this.port,
    );
  }
}

/// One-tap endpoint presets. [hint] is shown in the endpoint field.
class ProviderPreset {
  final ProviderType type;
  final String endpointTemplate;
  final String hint;
  final String help;

  const ProviderPreset({
    required this.type,
    required this.endpointTemplate,
    required this.hint,
    required this.help,
  });
}

class ProviderPresets {
  static const List<ProviderPreset> all = [
    ProviderPreset(
      type: ProviderType.aws,
      endpointTemplate: 's3.{region}.amazonaws.com',
      hint: 's3.us-east-1.amazonaws.com',
      help: 'Region is part of the endpoint. Use IAM access keys.',
    ),
    ProviderPreset(
      type: ProviderType.cloudflareR2,
      endpointTemplate: '<account-id>.r2.cloudflarestorage.com',
      hint: '<account-id>.r2.cloudflarestorage.com',
      help: 'From Cloudflare dashboard → R2 → Manage API tokens. Region stays "auto".',
    ),
    ProviderPreset(
      type: ProviderType.wasabi,
      endpointTemplate: 's3.{region}.wasabisys.com',
      hint: 's3.us-east-1.wasabisys.com',
      help: 'Region examples: us-east-1, eu-west-1, ap-northeast-1.',
    ),
    ProviderPreset(
      type: ProviderType.backblazeB2,
      endpointTemplate: 's3.{region}.backblazeb2.com',
      hint: 's3.us-west-002.backblazeb2.com',
      help:
          'Use the S3 endpoint shown in B2 → Buckets, plus an application key.',
    ),
    ProviderPreset(
      type: ProviderType.minio,
      endpointTemplate: 'host:port',
      hint: '192.168.1.10:9000',
      help: 'Self-hosted MinIO. Path-style is forced on. Disable SSL for plain HTTP dev servers.',
    ),
    ProviderPreset(
      type: ProviderType.custom,
      endpointTemplate: 'host',
      hint: 's3.example.com',
      help: 'Any S3-compatible server (SeaweedFS, Garage, Ceph, Storj, …). Toggle path-style if listing fails.',
    ),
  ];

  /// Resolve `{region}` in the template for display purposes.
  static String resolveEndpoint(ProviderType type, String region) {
    final preset = all.firstWhere((p) => p.type == type);
    return preset.endpointTemplate.replaceAll('{region}', region);
  }
}
