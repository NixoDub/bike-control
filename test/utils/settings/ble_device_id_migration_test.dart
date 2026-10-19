import 'dart:convert';

import 'package:bike_control/utils/settings/ble_device_id_migration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// universal_ble 3 emits lower-case device ids; settings written by older
/// builds carry upper-case MACs (Android) / UUIDs (Apple). The one-time
/// migration rewrites those so riders keep everything keyed by their devices.
void main() {
  const mac = 'AA:BB:CC:DD:EE:0F';
  const macLc = 'aa:bb:cc:dd:ee:0f';
  const uuid = '9F1C2A3B-4D5E-6F70-8192-A3B4C5D6E7F8';
  const uuidLc = '9f1c2a3b-4d5e-6f70-8192-a3b4c5d6e7f8';

  Future<SharedPreferences> migrated(Map<String, Object> initial) async {
    SharedPreferences.setMockInitialValues(initial);
    final prefs = await SharedPreferences.getInstance();
    await migrateBleDeviceIds(prefs);
    return prefs;
  }

  group('keys with a device id inside', () {
    test('per-device keys move to the lower-case id with their value', () async {
      final prefs = await migrated({
        'sensor_auto_connect_$mac': true,
        'ltwoo_pin_$mac': '123',
        'ltwoo_anchor_gear_$mac': true,
        'ltwoo_shift_orientation_inverted_$mac': true,
        'sram_key_$mac': 'deadbeef',
        'sram_config_backup_$mac': '{"a":1}',
        'sram_disabled_$mac': true,
        'sram_buttons_$mac': <String>['123:4:5'],
        'sram_shifters_$mac': <String>['123:4:5'],
        'shimano_button_mode_$uuid': true,
        'shimano_passkey_$uuid': '000123',
        'clickV2_${mac}_unlock_date': 1700000000000,
        'clickV2_${mac}_notSure': true,
        'rideV2_${uuid}_unlock_date': 1700000000001,
        'rideV2_${uuid}_notSure': true,
        // Trainer keys fall back to the device id for a trainer without a name.
        'retrofit_mode_$mac': 'wifi',
        'auto_connect_$mac': true,
        'control_protocol_$mac': 'ftms',
        'self_test_$mac': '{"ok":true}',
      });

      expect(prefs.getBool('sensor_auto_connect_$macLc'), isTrue);
      expect(prefs.getString('ltwoo_pin_$macLc'), '123');
      expect(prefs.getBool('ltwoo_anchor_gear_$macLc'), isTrue);
      expect(prefs.getBool('ltwoo_shift_orientation_inverted_$macLc'), isTrue);
      expect(prefs.getString('sram_key_$macLc'), 'deadbeef');
      expect(prefs.getString('sram_config_backup_$macLc'), '{"a":1}');
      expect(prefs.getBool('sram_disabled_$macLc'), isTrue);
      expect(prefs.getStringList('sram_buttons_$macLc'), ['123:4:5']);
      expect(prefs.getStringList('sram_shifters_$macLc'), ['123:4:5']);
      expect(prefs.getBool('shimano_button_mode_$uuidLc'), isTrue);
      expect(prefs.getString('shimano_passkey_$uuidLc'), '000123');
      expect(prefs.getInt('clickV2_${macLc}_unlock_date'), 1700000000000);
      expect(prefs.getBool('clickV2_${macLc}_notSure'), isTrue);
      expect(prefs.getInt('rideV2_${uuidLc}_unlock_date'), 1700000000001);
      expect(prefs.getBool('rideV2_${uuidLc}_notSure'), isTrue);
      expect(prefs.getString('retrofit_mode_$macLc'), 'wifi');
      expect(prefs.getBool('auto_connect_$macLc'), isTrue);
      expect(prefs.getString('control_protocol_$macLc'), 'ftms');
      expect(prefs.getString('self_test_$macLc'), '{"ok":true}');

      // The upper-case originals are gone, nothing is left behind twice.
      expect(prefs.getKeys().where((k) => k.contains(mac) || k.contains(uuid)), isEmpty);
    });

    test('keys of name-keyed trainers and non-BLE ids are left alone', () async {
      final prefs = await migrated({
        'auto_connect_KICKR CORE 1234': true,
        'retrofit_mode_KICKR CORE 1234': 'wifi',
        'auto_connect_dircon://KICKR CORE 1234': true,
        'sensor_auto_connect_emulated:hrm': true,
        // Not a per-device store at all, even though the value is UUID-shaped.
        'mdns_install_id': uuid,
        'some_other_$mac': true,
      });

      expect(prefs.getBool('auto_connect_KICKR CORE 1234'), isTrue);
      expect(prefs.getString('retrofit_mode_KICKR CORE 1234'), 'wifi');
      expect(prefs.getBool('auto_connect_dircon://KICKR CORE 1234'), isTrue);
      expect(prefs.getBool('sensor_auto_connect_emulated:hrm'), isTrue);
      expect(prefs.getString('mdns_install_id'), uuid);
      expect(prefs.getBool('some_other_$mac'), isTrue);
    });

    test('an already lower-case key wins over the upper-case leftover', () async {
      final prefs = await migrated({
        'ltwoo_pin_$mac': '111',
        'ltwoo_pin_$macLc': '222',
      });

      expect(prefs.getString('ltwoo_pin_$macLc'), '222');
      expect(prefs.containsKey('ltwoo_pin_$mac'), isFalse);
    });
  });

  group('values holding a device id', () {
    test('ignored devices: BLE ids lower-cased, names and other ids untouched, order kept', () async {
      final prefs = await migrated({
        'ignored_device_ids': <String>[mac, 'dircon://KICKR CORE 1234', uuid, 'emulated:zwift-click'],
        'ignored_device_names': <String>['Zwift Click', 'KICKR CORE 1234', 'RDR', 'Emulated'],
      });

      expect(prefs.getStringList('ignored_device_ids'), [
        macLc,
        'dircon://KICKR CORE 1234',
        uuidLc,
        'emulated:zwift-click',
      ]);
      expect(prefs.getStringList('ignored_device_names'), ['Zwift Click', 'KICKR CORE 1234', 'RDR', 'Emulated']);
    });

    test('sensor selections pointing at a BLE sensor are lower-cased', () async {
      final prefs = await migrated({
        'sensor_selection_heartRate': mac,
        'sensor_selection_power': 'healthkit',
        'sensor_selection_cadence': 'emulated:csc',
      });

      expect(prefs.getString('sensor_selection_heartRate'), macLc);
      expect(prefs.getString('sensor_selection_power'), 'healthkit');
      expect(prefs.getString('sensor_selection_cadence'), 'emulated:csc');
    });

    test('remembered devices: deviceId lower-cased, every other field preserved', () async {
      final entries = [
        {
          'deviceId': mac,
          'name': 'Zwift Click',
          'kind': 'controller',
          'lastConnected': '2026-10-01T10:00:00.000',
          'services': ['00000001-19ca-4651-86e5-fa29dcdd09d1'],
          'manufacturerData': [
            {'companyId': 2378, 'payload': 'CQ=='},
          ],
        },
        {
          'deviceId': 'dircon://KICKR CORE 1234',
          'name': 'KICKR CORE 1234',
          'kind': 'trainer',
          'lastConnected': '2026-10-01T10:00:00.000',
          'services': <String>[],
          'manufacturerData': <Object>[],
        },
      ];
      final prefs = await migrated({'remembered_devices': jsonEncode(entries)});

      final result = jsonDecode(prefs.getString('remembered_devices')!) as List;
      expect(result[0]['deviceId'], macLc);
      expect(result[0]['name'], 'Zwift Click');
      expect(result[0]['services'], ['00000001-19ca-4651-86e5-fa29dcdd09d1']);
      expect(result[0]['manufacturerData'], [
        {'companyId': 2378, 'payload': 'CQ=='},
      ]);
      expect(result[1]['deviceId'], 'dircon://KICKR CORE 1234');
    });

    test('keymaps: button deviceIds of BLE devices lower-cased, gamepad/HID ids kept', () async {
      final keyPair = {
        'actions': [
          'shiftUp',
          {'name': 'shiftDown', 'deviceId': mac},
          {'name': 'button-7', 'deviceId': '12'},
          {'name': 'mediaPlay', 'deviceId': 'HID Device'},
          {'name': 'paddleLeft', 'deviceId': uuid},
        ],
        'trigger': 'singleClick',
        'inGameAction': 'shiftDown',
        'touchPosition': {'x': 10.5, 'y': 20.0},
      };
      final prefs = await migrated({
        'customapp_My Profile': <String>[jsonEncode(keyPair), 'not json'],
        'app': 'My Profile',
      });

      final stored = prefs.getStringList('customapp_My Profile')!;
      final decoded = jsonDecode(stored[0]) as Map<String, dynamic>;
      expect(decoded['actions'], [
        'shiftUp',
        {'name': 'shiftDown', 'deviceId': macLc},
        {'name': 'button-7', 'deviceId': '12'},
        {'name': 'mediaPlay', 'deviceId': 'HID Device'},
        {'name': 'paddleLeft', 'deviceId': uuidLc},
      ]);
      expect(decoded['trigger'], 'singleClick');
      expect(decoded['inGameAction'], 'shiftDown');
      expect(decoded['touchPosition'], {'x': 10.5, 'y': 20.0});
      // An entry it cannot parse is kept verbatim rather than dropped.
      expect(stored[1], 'not json');
      expect(prefs.getString('app'), 'My Profile');
    });

    test('shifting configs keyed by a nameless trainer id are lower-cased', () async {
      final configs = [
        {'trainerKey': mac, 'name': 'A', 'maxGear': 24},
        {'trainerKey': 'KICKR CORE 1234', 'name': 'B'},
      ];
      final prefs = await migrated({'shifting_configs': jsonEncode(configs)});

      final result = jsonDecode(prefs.getString('shifting_configs')!) as List;
      expect(result[0], {'trainerKey': macLc, 'name': 'A', 'maxGear': 24});
      expect(result[1], {'trainerKey': 'KICKR CORE 1234', 'name': 'B'});
    });
  });

  group('one-time', () {
    test('records its version and does not run again', () async {
      SharedPreferences.setMockInitialValues({'ltwoo_pin_$mac': '123'});
      final prefs = await SharedPreferences.getInstance();

      expect(await migrateBleDeviceIds(prefs), isTrue);
      expect(prefs.getInt(bleDeviceIdMigrationVersionKey), bleDeviceIdMigrationVersion);

      // Anything upper-case written afterwards is not this migration's business.
      await prefs.setString('ltwoo_pin_$uuid', '456');
      expect(await migrateBleDeviceIds(prefs), isFalse);
      expect(prefs.getString('ltwoo_pin_$uuid'), '456');
      expect(prefs.getString('ltwoo_pin_$macLc'), '123');
    });

    test('running it on already-migrated data changes nothing', () async {
      final initial = <String, Object>{
        'ltwoo_pin_$macLc': '123',
        'ignored_device_ids': <String>[macLc],
        'ignored_device_names': <String>['X'],
        'sensor_selection_heartRate': macLc,
      };
      final prefs = await migrated(initial);
      for (final entry in initial.entries) {
        expect(prefs.get(entry.key), entry.value, reason: entry.key);
      }
    });

    test('a fresh install is just marked as migrated', () async {
      final prefs = await migrated({});
      expect(prefs.getKeys(), {bleDeviceIdMigrationVersionKey});
    });

    test('is skipped on web, where device ids are opaque', () async {
      SharedPreferences.setMockInitialValues({'ltwoo_pin_$mac': '123'});
      final prefs = await SharedPreferences.getInstance();

      expect(await migrateBleDeviceIds(prefs, isWeb: true), isFalse);
      expect(prefs.getString('ltwoo_pin_$mac'), '123');
    });
  });
}
