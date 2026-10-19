import 'package:bike_control/bluetooth/devices/bluetooth_device.dart';
import 'package:bike_control/bluetooth/devices/proxy/proxy_device.dart';
import 'package:bike_control/bluetooth/devices/sensors/ble_power_device.dart';
import 'package:bike_control/bluetooth/devices/stages/stages_smart_bike.dart';
import 'package:bike_control/services/sensors/ble_sensor_source.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/support/intake_options.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:universal_ble/universal_ble.dart';

/// A Stages smart bike is one peripheral that is both a smart trainer and the
/// host of its own shift buttons. Scan-time classification must keep it on the
/// controller class whatever trainer services it advertises — the trainer role
/// is attached at connect time from the discovered GATT database (see
/// `test/integration/stages_smart_bike_trainer_test.dart`). The brand name is
/// also a power-meter prefix, so a plain Stages power meter must stay one.
void main() {
  core.actionHandler = StubActions();

  BleDevice scan(String name, {List<String> services = const []}) =>
      BleDevice(deviceId: 'id-$name', name: name, services: services);

  final bikeServices = [
    FitnessBikeDefinition.FITNESS_MACHINE_SERVICE_UUID.toLowerCase(),
    BleSensorSource.cscServiceUuid,
    BleSensorSource.cyclingPowerServiceUuid,
  ];

  for (final web in [false, true]) {
    group(web ? 'web' : 'native', () {
      setUp(() => BluetoothDevice.debugIsWeb = () => web);
      tearDown(() => BluetoothDevice.debugIsWeb = null);

      test('Stages Bike advertising FTMS + CSC + CPS is the button host, not a trainer or power meter', () {
        final device = BluetoothDevice.fromScanResult(scan('Stages Bike 0017', services: bikeServices));
        expect(device, isA<StagesSmartBike>());
        expect(device, isNot(isA<ProxyDevice>()));
        expect(device, isNot(isA<BlePowerDevice>()));
      });

      test('Stages Bike without advertised services is the button host too', () {
        expect(BluetoothDevice.fromScanResult(scan('Stages Bike 0105')), isA<StagesSmartBike>());
      });

      test('the name match ignores case', () {
        expect(BluetoothDevice.fromScanResult(scan('STAGES BIKE 0105')), isA<StagesSmartBike>());
      });

      test('a Stages power meter stays a power meter', () {
        final device = BluetoothDevice.fromScanResult(
          scan('Stages Power L', services: [BleSensorSource.cyclingPowerServiceUuid]),
        );
        expect(device, isA<BlePowerDevice>());
      });

      test('the bike is in beta', () {
        expect(BluetoothDevice.fromScanResult(scan('Stages Bike 0017'))!.isBeta, isTrue);
      });
    });
  }

  test('the support intake knows the bike as a Stages controller', () {
    final bike = StagesSmartBike(scan('Stages Bike 0017'));
    expect(controllerOptionIdFor(bike), 'stages');
    expect(controllerOptions.map((o) => o.id), contains('stages'));
  });
}
