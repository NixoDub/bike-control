import 'dart:typed_data';

import 'package:bike_control/bluetooth/devices/bluetooth_device.dart';
import 'package:bike_control/services/sensors/ble_sensor_source.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

const _batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
const _batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';

/// Drives [BluetoothDevice.connect] through its @protected upstream seams so
/// no BLE platform is needed. Mimics a heart rate strap that exposes the
/// Battery Service alongside Heart Rate.
class _FakeStrap extends BluetoothDevice {
  _FakeStrap({required this.batteryRead})
    : super(BleDevice(deviceId: 'strap-1', name: 'Strap'), availableButtons: const []);

  final Future<Uint8List> Function() batteryRead;
  List<BleService>? handledServices;

  @override
  Future<void> connectUpstream() async {}

  @override
  Future<List<BleService>> discoverUpstreamServices() async => [
    BleService(_batteryService, [
      BleCharacteristic(_batteryLevel, [CharacteristicProperty.read], []),
    ]),
    BleService(BleSensorSource.heartRateServiceUuid, [
      BleCharacteristic(BleSensorSource.heartRateMeasurementUuid, [CharacteristicProperty.notify], []),
    ]),
  ];

  @override
  Future<Uint8List> readUpstream(String serviceUuid, String characteristicUuid) {
    if (characteristicUuid.toLowerCase() == _batteryLevel) return batteryRead();
    throw StateError('unexpected read of $characteristicUuid');
  }

  @override
  Future<void> handleServices(List<BleService> services) async {
    handledServices = services;
  }

  @override
  Future<void> processCharacteristic(String characteristic, Uint8List bytes) async {}
}

void main() {
  // The failure path funnels through recordError, which persists the entry
  // via platform channels.
  TestWidgetsFlutterBinding.ensureInitialized();
  core.actionHandler = StubActions();

  test('reads the battery level when the characteristic is readable', () async {
    final device = _FakeStrap(batteryRead: () async => Uint8List.fromList([77]));

    await device.connect();

    expect(device.batteryLevel, 77);
    expect(device.handledServices, isNotNull);
  });

  // An encrypted Battery Level characteristic (device not bonded) rejects the
  // read with "Encryption is insufficient". Battery is optional metadata: the
  // connect must still reach handleServices, or the device is dropped and
  // reconnected in a loop.
  test('a failing battery read does not fail the connect', () async {
    final device = _FakeStrap(
      batteryRead: () async => throw Exception('Encryption is insufficient.'),
    );

    await device.connect();

    expect(device.batteryLevel, isNull);
    expect(device.handledServices, isNotNull);
  });

  test('a battery characteristic that vanished after discovery does not fail the connect', () async {
    final device = _FakeStrap(
      batteryRead: () async => throw Exception('Unknown characteristic: $_batteryLevel'),
    );

    await device.connect();

    expect(device.handledServices, isNotNull);
  });
}
