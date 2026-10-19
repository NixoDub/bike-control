import 'package:flutter/foundation.dart';

/// Helpers for BLE device ids across the universal_ble 2 → 3 change.
///
/// universal_ble 3 emits every BLE device id in lower-case (2.x reported the
/// platform's own case: upper-case MACs on Android/Linux, upper-case
/// peripheral UUIDs on iOS/macOS, lower-case on Windows). Ids the app stored
/// under 2.x, or receives from an install that still runs it (settings sync,
/// keymap import), therefore have to be brought into the same form before
/// they are compared to a live device.
///
/// Only ids that look like a Bluetooth address are touched. Everything else
/// the app keeps next to them — `dircon://…` WiFi trainers, `emulated:…`,
/// gamepad and HID ids, `healthkit`, opaque Web Bluetooth ids — is
/// case-sensitive and must stay verbatim.

final _macAddress = RegExp(r'^[0-9A-Fa-f]{2}([:-])[0-9A-Fa-f]{2}(\1[0-9A-Fa-f]{2}){4}$');
final _uuid = RegExp(r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$');

/// Whether [id] is a BLE device id in address form: a MAC
/// (`AA:BB:CC:DD:EE:FF`, Android/Windows/Linux) or a peripheral UUID
/// (iOS/macOS).
bool isBleAddressId(String id) => _macAddress.hasMatch(id) || _uuid.hasMatch(id);

/// [id] in the form universal_ble 3 emits: lower-case for a BLE address,
/// unchanged for anything else.
String canonicalBleDeviceId(String id) => isBleAddressId(id) ? id.toLowerCase() : id;

/// Null-tolerant [canonicalBleDeviceId].
String? canonicalBleDeviceIdOrNull(String? id) => id == null ? null : canonicalBleDeviceId(id);

/// Whether [a] and [b] name the same device, treating BLE addresses
/// case-insensitively and every other id verbatim.
bool bleDeviceIdsEqual(String? a, String? b) => canonicalBleDeviceIdOrNull(a) == canonicalBleDeviceIdOrNull(b);

/// [id] in the case universal_ble 2 emitted it on this platform: upper-case
/// everywhere but Windows. Only for values derived from a device id that
/// other apps have already seen and must keep seeing unchanged (e.g. the
/// bridge's advertised serial number).
String legacyCaseBleDeviceId(String id) {
  if (!isBleAddressId(id)) return id;
  return defaultTargetPlatform == TargetPlatform.windows ? id.toLowerCase() : id.toUpperCase();
}
