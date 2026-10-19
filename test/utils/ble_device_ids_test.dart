import 'package:bike_control/utils/ble_device_ids.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isBleAddressId', () {
    test('recognises MAC addresses and Apple peripheral UUIDs in any case', () {
      expect(isBleAddressId('AA:BB:CC:DD:EE:0F'), isTrue);
      expect(isBleAddressId('aa:bb:cc:dd:ee:0f'), isTrue);
      expect(isBleAddressId('AA-BB-CC-DD-EE-0F'), isTrue);
      expect(isBleAddressId('9F1C2A3B-4D5E-6F70-8192-A3B4C5D6E7F8'), isTrue);
    });

    test('rejects every non-BLE id the app stores next to BLE ids', () {
      for (final id in [
        'dircon://KICKR CORE 1234',
        'emulated:hrm',
        'healthkit',
        'HID Device',
        'gyroscope_steering_device',
        '12',
        'hid-3',
        // Windows gamepad id: 64 hex characters, no separators.
        'a' * 64,
        // Bare 12-hex string: never emitted as a BLE id by any platform here.
        'AABBCCDDEE0F',
        // Web Bluetooth id: an opaque base64 token.
        'Zk9/ZxJ3q0dM0yZb0Zt2Fw==',
        'KICKR CORE 1234',
        '',
      ]) {
        expect(isBleAddressId(id), isFalse, reason: id);
      }
    });
  });

  group('canonicalBleDeviceId', () {
    test('lower-cases BLE addresses, like universal_ble 3 emits them', () {
      expect(canonicalBleDeviceId('AA:BB:CC:DD:EE:0F'), 'aa:bb:cc:dd:ee:0f');
      expect(
        canonicalBleDeviceId('9F1C2A3B-4D5E-6F70-8192-A3B4C5D6E7F8'),
        '9f1c2a3b-4d5e-6f70-8192-a3b4c5d6e7f8',
      );
    });

    test('leaves non-BLE ids untouched', () {
      expect(canonicalBleDeviceId('HID Device'), 'HID Device');
      expect(canonicalBleDeviceId('dircon://KICKR CORE 1234'), 'dircon://KICKR CORE 1234');
      expect(canonicalBleDeviceId('Zk9/ZxJ3q0dM0yZb0Zt2Fw=='), 'Zk9/ZxJ3q0dM0yZb0Zt2Fw==');
    });

    test('bleDeviceIdsEqual compares BLE addresses case-insensitively only', () {
      expect(bleDeviceIdsEqual('AA:BB:CC:DD:EE:0F', 'aa:bb:cc:dd:ee:0f'), isTrue);
      expect(bleDeviceIdsEqual('HID Device', 'hid device'), isFalse);
      expect(bleDeviceIdsEqual(null, null), isTrue);
      expect(bleDeviceIdsEqual('aa:bb:cc:dd:ee:0f', null), isFalse);
    });
  });

  group('legacyCaseBleDeviceId (the id as universal_ble 2 emitted it)', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.linux]) {
      test('${platform.name}: upper-case', () {
        debugDefaultTargetPlatformOverride = platform;
        expect(legacyCaseBleDeviceId('aa:bb:cc:dd:ee:0f'), 'AA:BB:CC:DD:EE:0F');
      });
    }

    test('windows: lower-case, as it always was', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(legacyCaseBleDeviceId('AA:BB:CC:DD:EE:0F'), 'aa:bb:cc:dd:ee:0f');
    });

    test('non-BLE ids are returned unchanged', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(legacyCaseBleDeviceId('dircon://kickr'), 'dircon://kickr');
    });
  });
}
