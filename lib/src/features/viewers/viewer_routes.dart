// Maps objects to the top-level viewer route (see app.dart).

import 'viewer_kind.dart';

/// Top-level go_router location for [key], or null when no viewer exists.
String? viewerRouteForKey(String key) => switch (viewerKindForKey(key)) {
  ViewerKind.image => '/view/image',
  ViewerKind.text => '/view/text',
  ViewerKind.pdf => '/view/pdf',
  ViewerKind.video => '/view/video',
  ViewerKind.audio => '/view/audio',
  null => null,
};

/// Full location including query params for the viewer.
String viewerLocation({
  required String route,
  required String accountId,
  required String bucket,
  required String key,
}) => Uri(
  path: route,
  queryParameters: {'accountId': accountId, 'bucket': bucket, 'key': key},
).toString();
