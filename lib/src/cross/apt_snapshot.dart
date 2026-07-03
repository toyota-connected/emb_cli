// Date-pinned apt mirrors. A distro's live mirror serves whatever versions are
// current today, so two sysroot builds months apart resolve different packages
// for the same declared inputs. The snapshot services keep every historical
// state addressable by timestamp; rewriting a mirror URL to its snapshot form
// makes `-dev` resolution a pure function of the declared date.

/// Normalize a declared snapshot [date] to the `YYYYMMDDTHHMMSSZ` stamp the
/// snapshot services expect. Accepts a bare date (`2024-06-01`), a date with a
/// time (`2024-06-01 12:00:00`), or an already-normalized stamp; a bare date
/// defaults to midnight UTC. Returns null when the input can't be parsed.
String? snapshotTimestamp(String date) {
  final trimmed = date.trim();
  // Already a snapshot stamp.
  if (RegExp(r'^\d{8}T\d{6}Z$').hasMatch(trimmed)) return trimmed;

  final m = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})'
    r'(?:[ T](\d{2}):(\d{2}):(\d{2}))?Z?$',
  ).firstMatch(trimmed);
  if (m == null) return null;
  final ymd = '${m[1]}${m[2]}${m[3]}';
  final hms = '${m[4] ?? '00'}${m[5] ?? '00'}${m[6] ?? '00'}';
  return '${ymd}T${hms}Z';
}

/// The snapshot service base for each known live mirror host+path prefix. Keys
/// are matched as a prefix of the mirror URL; the longest match wins.
const _snapshotBases = <String, String>{
  'http://deb.debian.org/debian': 'https://snapshot.debian.org/archive/debian',
  'https://deb.debian.org/debian': 'https://snapshot.debian.org/archive/debian',
  'http://deb.debian.org/debian-security':
      'https://snapshot.debian.org/archive/debian-security',
  'https://deb.debian.org/debian-security':
      'https://snapshot.debian.org/archive/debian-security',
  'http://security.debian.org/debian-security':
      'https://snapshot.debian.org/archive/debian-security',
  'https://security.debian.org/debian-security':
      'https://snapshot.debian.org/archive/debian-security',
  'http://raspbian.raspberrypi.org/raspbian':
      'http://snapshot.raspbian.org/raspbian',
  'http://raspbian.raspberrypi.com/raspbian':
      'http://snapshot.raspbian.org/raspbian',
};

/// Rewrite a live mirror [url] to its date-pinned snapshot form at [timestamp]
/// (a `YYYYMMDDTHHMMSSZ` stamp from [snapshotTimestamp]). Returns null when the
/// URL's host isn't a mirror with a known snapshot service, so the caller can
/// warn and fall back to the live mirror rather than silently mis-resolving.
///
/// `http://deb.debian.org/debian/dists/bookworm/…` at `20240601T000000Z`
/// becomes
/// `https://snapshot.debian.org/archive/debian/20240601T000000Z/dists/bookworm/…`.
String? snapshotRewrite(String url, String timestamp) {
  String? bestKey;
  for (final key in _snapshotBases.keys) {
    if (url == key || url.startsWith('$key/')) {
      if (bestKey == null || key.length > bestKey.length) bestKey = key;
    }
  }
  if (bestKey == null) return null;
  final rest = url.substring(bestKey.length); // leading '/…' or ''
  return '${_snapshotBases[bestKey]}/$timestamp$rest';
}
