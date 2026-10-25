import 'dart:typed_data';

/// The tail every 16- and 32-bit Bluetooth SIG UUID is expanded with.
const String _sigBaseSuffix = '-0000-1000-8000-00805f9b34fb';

/// The full lower-case `8-4-4-4-12` form of a Bluetooth UUID, whichever way it
/// was spelled: `1826`, `0x1826`, `00001826`, the dashed 128-bit form in any
/// case, or the 32 hex digits without dashes. Anything else comes back
/// lower-cased and trimmed.
String normalizeUuid(String uuid) {
  var u = uuid.trim().toLowerCase();
  if (u.startsWith('0x')) u = u.substring(2);
  if (u.length == 4) return '0000$u$_sigBaseSuffix';
  if (u.length == 8) return '$u$_sigBaseSuffix';
  if (u.length == 32 && !u.contains('-')) {
    return '${u.substring(0, 8)}-${u.substring(8, 12)}-${u.substring(12, 16)}-${u.substring(16, 20)}-${u.substring(20)}';
  }
  return u;
}

/// The 16 big-endian bytes a UUID takes on the DirCon wire.
Uint8List uuidToBytes(String uuid) {
  final hex = normalizeUuid(uuid).replaceAll('-', '');
  if (hex.length != 32) throw FormatException('Not a Bluetooth UUID', uuid);
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// The inverse of [uuidToBytes]: the full lower-case dashed form of 16 bytes.
String uuidFromBytes(List<int> bytes) {
  if (bytes.length != 16) throw ArgumentError.value(bytes.length, 'bytes.length', 'A UUID is 16 bytes');
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The four-digit short form (`1826`) of a UUID on the Bluetooth SIG base, or
/// null for a custom 128-bit UUID.
String? shortUuidOf(String uuid) {
  final n = normalizeUuid(uuid);
  if (n.startsWith('0000') && n.endsWith(_sigBaseSuffix)) return n.substring(4, 8);
  return null;
}
