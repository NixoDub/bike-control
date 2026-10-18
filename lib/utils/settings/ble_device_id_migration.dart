import 'dart:convert';

import 'package:bike_control/main.dart';
import 'package:bike_control/utils/ble_device_ids.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pref recording which version of [migrateBleDeviceIds] already ran.
const bleDeviceIdMigrationVersionKey = 'ble_device_id_migration_version';

/// Bump only together with a new migration step below.
const bleDeviceIdMigrationVersion = 1;

/// Per-device keys: `<prefix><deviceId>`. The trainer keys use the trainer's
/// name and only fall back to the device id for a trainer without one — the
/// suffix must look like a BLE address for a key to be touched at all.
const _deviceKeyPrefixes = [
  'sensor_auto_connect_',
  'ltwoo_pin_',
  'ltwoo_anchor_gear_',
  'ltwoo_shift_orientation_inverted_',
  'sram_key_',
  'sram_config_backup_',
  'sram_disabled_',
  'sram_buttons_',
  'sram_shifters_',
  'shimano_button_mode_',
  'shimano_passkey_',
  'retrofit_mode_',
  'auto_connect_',
  'control_protocol_',
  'self_test_',
];

/// Zwift unlock bookkeeping: `<family>_<deviceId>_<field>`.
final _unlockKey = RegExp(r'^(clickV2|rideV2)_(.+)_(unlock_date|notSure)$');

const _ignoredDeviceIdsKey = 'ignored_device_ids';
const _sensorSelectionPrefix = 'sensor_selection_';
const _rememberedDevicesKey = 'remembered_devices';
const _keymapPrefix = 'customapp_';
const _shiftingConfigsKey = 'shifting_configs';

/// One-time rewrite of stored BLE device ids to the lower-case form
/// universal_ble 3 emits (see `ble_device_ids.dart`), so settings written by
/// older builds — Android stored upper-case MACs, iOS/macOS upper-case UUIDs —
/// still match the live devices: auto-connects, PINs and passkeys, button
/// modes, unlock state, ignored and remembered devices, sensor selections,
/// per-device keymap buttons and shifting configs.
///
/// Rewrites, for ids that look like a BLE address only:
/// - the id inside the per-device keys listed in [_deviceKeyPrefixes] and
///   the Zwift unlock keys ([_unlockKey]), keeping the value;
/// - the entries of `ignored_device_ids`, the `sensor_selection_*` values,
///   `deviceId` in `remembered_devices`, the button `deviceId`s inside every
///   `customapp_*` keymap entry and `trainerKey` in `shifting_configs`.
///
/// Every other value (WiFi `dircon://` ids, `emulated:` ids, gamepad and HID
/// ids, account and install ids) is left alone. Skipped on web, whose ids are
/// opaque. Runs once — guarded by [bleDeviceIdMigrationVersionKey] — and is
/// idempotent anyway. Returns whether it ran.
Future<bool> migrateBleDeviceIds(SharedPreferences prefs, {bool isWeb = false}) async {
  if (isWeb) return false;
  if ((prefs.getInt(bleDeviceIdMigrationVersionKey) ?? 0) >= bleDeviceIdMigrationVersion) return false;

  for (final key in prefs.getKeys().toList()) {
    try {
      await _migrateKey(prefs, key);
    } catch (e, s) {
      // One broken entry must not cost the rider the rest of their settings.
      recordError(e, s, context: 'BleDeviceIdMigration.$key');
    }
  }

  await prefs.setInt(bleDeviceIdMigrationVersionKey, bleDeviceIdMigrationVersion);
  return true;
}

Future<void> _migrateKey(SharedPreferences prefs, String key) async {
  final value = prefs.get(key);
  if (value == null) return;

  if (key == _ignoredDeviceIdsKey) {
    final ids = prefs.getStringList(key);
    if (ids != null) await _setIfChanged(prefs, key, ids, ids.map(canonicalBleDeviceId).toList());
    return;
  }
  if (key.startsWith(_sensorSelectionPrefix) && value is String) {
    await _setIfChanged(prefs, key, value, canonicalBleDeviceId(value));
    return;
  }
  if (key == _rememberedDevicesKey && value is String) {
    await _setIfChanged(prefs, key, value, _rewriteJsonList(value, 'deviceId'));
    return;
  }
  if (key == _shiftingConfigsKey && value is String) {
    await _setIfChanged(prefs, key, value, _rewriteJsonList(value, 'trainerKey'));
    return;
  }
  if (key.startsWith(_keymapPrefix)) {
    final entries = prefs.getStringList(key);
    if (entries != null) await _setIfChanged(prefs, key, entries, entries.map(_rewriteKeyPair).toList());
    return;
  }

  final renamed = _renamedDeviceKey(key);
  if (renamed == null || renamed == key) return;
  // A key already in the new form was written by a build that emits
  // lower-case ids — it is the current one, the leftover just goes.
  if (!prefs.containsKey(renamed)) await _write(prefs, renamed, value);
  await prefs.remove(key);
}

String? _renamedDeviceKey(String key) {
  for (final prefix in _deviceKeyPrefixes) {
    if (!key.startsWith(prefix)) continue;
    final id = key.substring(prefix.length);
    return isBleAddressId(id) ? '$prefix${id.toLowerCase()}' : null;
  }
  final unlock = _unlockKey.firstMatch(key);
  if (unlock != null && isBleAddressId(unlock.group(2)!)) {
    return '${unlock.group(1)}_${unlock.group(2)!.toLowerCase()}_${unlock.group(3)}';
  }
  return null;
}

/// [raw] is a JSON list of objects; lower-cases [field] in each where it is
/// a BLE address. Returns [raw] unchanged when nothing needed rewriting.
String _rewriteJsonList(String raw, String field) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) return raw;
  var changed = false;
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final id = entry[field];
    if (id is String && canonicalBleDeviceId(id) != id) {
      entry[field] = canonicalBleDeviceId(id);
      changed = true;
    }
  }
  return changed ? jsonEncode(decoded) : raw;
}

/// One stored keymap entry (a KeyPair JSON object): lower-cases the
/// `deviceId` of every button in `actions`. An entry that does not parse is
/// returned verbatim — the keymap loader decides what to do with it.
String _rewriteKeyPair(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return raw;
  }
  if (decoded is! Map) return raw;
  final actions = decoded['actions'];
  if (actions is! List) return raw;
  var changed = false;
  for (final button in actions) {
    if (button is! Map) continue;
    final id = button['deviceId'];
    if (id is String && canonicalBleDeviceId(id) != id) {
      button['deviceId'] = canonicalBleDeviceId(id);
      changed = true;
    }
  }
  return changed ? jsonEncode(decoded) : raw;
}

Future<void> _setIfChanged(SharedPreferences prefs, String key, Object before, Object after) async {
  final unchanged = before is List && after is List ? _listEquals(before, after) : before == after;
  if (!unchanged) await _write(prefs, key, after);
}

bool _listEquals(List a, List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> _write(SharedPreferences prefs, String key, Object value) async {
  switch (value) {
    case bool v:
      await prefs.setBool(key, v);
    case int v:
      await prefs.setInt(key, v);
    case double v:
      await prefs.setDouble(key, v);
    case String v:
      await prefs.setString(key, v);
    case List v:
      await prefs.setStringList(key, v.cast<String>());
    default:
      throw ArgumentError.value(value, key, 'unsupported preference type');
  }
}
