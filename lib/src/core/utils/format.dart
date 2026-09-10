// Shared formatting helpers (bytes, dates) used across screens.

/// Human-readable byte size: `0 B`, `1.0 KB`, `2.5 MB`, …
/// Returns an empty string for null so callers can join conditionally.
String formatBytes(int? bytes, {int fractionDigits = 1}) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var v = bytes.toDouble();
  var u = -1;
  do {
    v /= 1024;
    u++;
  } while (v >= 1024 && u < units.length - 1);
  return '${v.toStringAsFixed(fractionDigits)} ${units[u]}';
}

/// Compact byte size without decimals for tiles/pills (`1.5 MB` stays the
/// same below 10, `125 KB`). Falls back to [formatBytes].
String formatBytesShort(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var v = bytes.toDouble();
  var u = -1;
  do {
    v /= 1024;
    u++;
  } while (v >= 1024 && u < units.length - 1);
  final digits = v >= 100 ? 0 : 1;
  return '${v.toStringAsFixed(digits)} ${units[u]}';
}
