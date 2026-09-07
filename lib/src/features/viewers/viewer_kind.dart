// Maps object keys to the in-app viewer that can open them.

enum ViewerKind { image, text, pdf, video, audio }

const _imageExts = {
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'bmp',
  'wbmp',
  'heic',
  'heif',
};

const _textExts = {
  'txt',
  'md',
  'markdown',
  'json',
  'xml',
  'csv',
  'log',
  'yaml',
  'yml',
  'toml',
  'ini',
  'cfg',
  'conf',
  'html',
  'htm',
  'css',
  'js',
  'ts',
  'dart',
  'py',
  'java',
  'kt',
  'swift',
  'sh',
  'sql',
  'c',
  'h',
  'cpp',
  'rs',
  'go',
  'env',
  'properties',
  'gradle',
  'r',
  'tex',
};

const _videoExts = {'mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp'};

/// Audio extensions handled by the inbuilt player (streamed via presigned
/// URL with just_audio → ExoPlayer on Android / AVPlayer on iOS).
/// Core playlist: mp3/m4a/aac/wav/flac/ogg/opus. Extras (aiff/midi/amr/wma
/// etc.) play where the OS decoder exists, otherwise the player surfaces a
/// clear error with a Download + open-externally fallback.
const _audioExts = {
  'mp3',
  'm4a',
  'aac',
  'wav',
  'wave',
  'ogg',
  'oga',
  'opus',
  'flac',
  'aiff',
  'aif',
  'amr',
  'mid',
  'midi',
  'wma',
  'mka',
  'weba',
  'mpga',
  'mp2',
  'ac3',
};

/// File extension of [key] (lowercase, no dot), or '' when there is none.
String extensionOfKey(String key) {
  final name = key.split('/').last;
  final idx = name.lastIndexOf('.');
  if (idx <= 0 || idx == name.length - 1) return '';
  return name.substring(idx + 1).toLowerCase();
}

/// Which in-app viewer opens [key], or null for download-only objects.
ViewerKind? viewerKindForKey(String key) {
  final ext = extensionOfKey(key);
  if (ext.isEmpty) return null;
  if (ext == 'pdf') return ViewerKind.pdf;
  if (_imageExts.contains(ext)) return ViewerKind.image;
  if (_textExts.contains(ext)) return ViewerKind.text;
  if (_audioExts.contains(ext)) return ViewerKind.audio;
  if (_videoExts.contains(ext)) return ViewerKind.video;
  return null;
}
