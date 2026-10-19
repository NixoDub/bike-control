import 'dart:convert';

import 'package:bike_control/models/remembered_device.dart';
import 'package:bike_control/models/shifting_config.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/keymap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The one-time migration fixes what is on disk at upgrade time, but
/// upper-case BLE ids keep arriving afterwards: settings sync and keymap
/// import carry data from installs that still run an older build. Every read
/// path that hands a stored device id to the app brings it into the
/// lower-case form universal_ble 3 emits, and leaves non-BLE ids alone.
void main() {
  const mac = 'AA:BB:CC:DD:EE:0F';
  const macLc = 'aa:bb:cc:dd:ee:0f';

  test('a keymap button keeps matching its device', () {
    final pair = KeyPair.decode(
      jsonEncode({
        'actions': [
          {'name': 'shiftUp', 'deviceId': mac},
          {'name': 'mediaPlay', 'deviceId': 'HID Device'},
        ],
      }),
    )!;
    expect(pair.buttons.map((b) => b.sourceDeviceId), [macLc, 'HID Device']);
  });

  test('a remembered device keeps its identity', () {
    final device = RememberedDevice.tryFromJson({'deviceId': mac, 'name': 'Zwift Click', 'kind': 'controller'})!;
    expect(device.deviceId, macLc);
    final wifi = RememberedDevice.tryFromJson({'deviceId': 'dircon://KICKR', 'kind': 'trainer'})!;
    expect(wifi.deviceId, 'dircon://KICKR');
  });

  test('a shifting config of a nameless trainer keeps its trainer', () {
    expect(ShiftingConfig.fromJson({'trainerKey': mac}).trainerKey, macLc);
    expect(ShiftingConfig.fromJson({'trainerKey': 'KICKR CORE 1234'}).trainerKey, 'KICKR CORE 1234');
  });

  group('settings', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'ignored_device_ids': <String>[mac, 'dircon://KICKR'],
        'ignored_device_names': <String>['Zwift Click', 'KICKR'],
        'sensor_selection_heartRate': mac,
      });
      core.settings.prefs = await SharedPreferences.getInstance();
    });

    test('an ignored device stays ignored', () {
      expect(core.settings.getIgnoredDevices().map((d) => d.id), [macLc, 'dircon://KICKR']);
    });

    test('un-ignoring by the live (lower-case) id removes the synced upper-case entry', () async {
      await core.settings.removeIgnoredDevice(macLc);
      expect(core.settings.getIgnoredDevices().map((d) => d.id), ['dircon://KICKR']);
    });

    test('ignoring an already-ignored device does not add it twice', () async {
      await core.settings.addIgnoredDevice(macLc, 'Zwift Click');
      expect(core.settings.getIgnoredDevices().map((d) => d.id), [macLc, 'dircon://KICKR']);
    });

    test('a selected BLE sensor stays selected', () {
      expect(core.settings.getSensorSelection('heartRate'), macLc);
    });
  });
}
