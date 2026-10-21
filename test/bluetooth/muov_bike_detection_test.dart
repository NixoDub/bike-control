import 'package:bike_control/bluetooth/devices/bluetooth_device.dart';
import 'package:bike_control/bluetooth/devices/muov/muov_bike.dart';
import 'package:bike_control/bluetooth/devices/proxy/proxy_device.dart';
import 'package:bike_control/bluetooth/devices/zwift/constants.dart';
import 'package:bike_control/services/sensors/ble_sensor_source.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/support/intake_options.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:universal_ble/universal_ble.dart';

/// A MUOV smart bike is one peripheral that is both an FTMS trainer and the
/// host of its hood buttons, which it sends over the Zwift Ride service
/// (FC82). It advertises FTMS + Cycling Power and FC82 service data, but no
/// Zwift manufacturer data, so only its name tells it apart from a trainer.
void main() {
  core.actionHandler = StubActions();

  BleDevice scan(String name, {List<String> services = const [], Map<String, Uint8List> serviceData = const {}}) =>
      BleDevice(deviceId: 'id-$name', name: name, services: services, serviceData: serviceData);

  final advertised = [
    FitnessBikeDefinition.FITNESS_MACHINE_SERVICE_UUID.toLowerCase(),
    BleSensorSource.cyclingPowerServiceUuid,
  ];
  final serviceData = {
    ZwiftConstants.ZWIFT_RIDE_CUSTOM_SERVICE_UUID.toLowerCase(): Uint8List.fromList([0x01, 0x02]),
  };

  for (final web in [false, true]) {
    group(web ? 'web' : 'native', () {
      setUp(() => BluetoothDevice.debugIsWeb = () => web);
      tearDown(() => BluetoothDevice.debugIsWeb = null);

      test('MUOV advertising FTMS + CPS + FC82 data is the button host, not a trainer', () {
        final device = BluetoothDevice.fromScanResult(
          scan('MUOV-1A2B3', services: advertised, serviceData: serviceData),
        );
        expect(device, isA<MuovBike>());
        expect(device, isNot(isA<ProxyDevice>()));
      });

      test('MUOV without advertised services is the button host too', () {
        expect(BluetoothDevice.fromScanResult(scan('MUOV-1A2B3')), isA<MuovBike>());
      });

      test('the name match ignores case', () {
        expect(BluetoothDevice.fromScanResult(scan('muov-1a2b3')), isA<MuovBike>());
      });

      test('the bike is in beta', () {
        expect(BluetoothDevice.fromScanResult(scan('MUOV-1A2B3'))!.isBeta, isTrue);
      });
    });
  }

  test('a MUOV never compares its firmware against the Zwift Ride releases', () {
    final bike = MuovBike(scan('MUOV-1A2B3'))..firmwareVersion = '1.0.0';
    expect(bike.latestFirmwareVersion, isNull);
    expect(bike.hasNewerFirmwareVersion, isFalse);
    expect(bike.hasFirmwareBeyondSupported, isFalse);
    expect(bike.isRideV2, isFalse);
    expect(bike.usesZwiftUnlock, isFalse);
  });

  test('the support intake does not file a MUOV as a Zwift Ride', () {
    expect(controllerOptionIdFor(MuovBike(scan('MUOV-1A2B3'))), 'other');
  });
}
