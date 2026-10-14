import 'package:bike_control/bluetooth/devices/bluetooth_device.dart';
import 'package:bike_control/bluetooth/devices/proxy/proxy_device.dart';
import 'package:bike_control/services/sensors/ble_sensor_source.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:universal_ble/universal_ble.dart';

/// Decathlon Van Rysel D100/D500-class trainers advertise as `VANRYSEL-HT…`
/// and are driven over FE-C-over-BLE (newer variants may expose FTMS
/// instead). Riders reported BikeControl never listing them during a scan
/// while the trainer app found them fine: an FE-C-only advertisement matched
/// no trainer rule, and on Windows the advertisement can arrive with no
/// services at all, leaving only the name.
void main() {
  core.actionHandler = StubActions();

  BleDevice scan(String name, {List<String> services = const []}) =>
      BleDevice(deviceId: 'id-$name', name: name, services: services);

  group('FE-C-only advertisement (native)', () {
    setUp(() => BluetoothDevice.debugIsWeb = () => false);
    tearDown(() => BluetoothDevice.debugIsWeb = null);

    test('a trainer advertising only the FE-C service is a ProxyDevice smart trainer', () {
      final device = BluetoothDevice.fromScanResult(
        scan('Some FE-C Trainer', services: [FitnessBikeDefinition.FEC_BLE_SERVICE_UUID]),
      );
      expect(device, isA<ProxyDevice>());
      expect((device as ProxyDevice).isSmartTrainer, isTrue);
    });

    test('a Van Rysel advertising only FE-C is a ProxyDevice smart trainer', () {
      final device = BluetoothDevice.fromScanResult(
        scan('VANRYSEL-HT-1a2b', services: [FitnessBikeDefinition.FEC_BLE_SERVICE_UUID]),
      );
      expect(device, isA<ProxyDevice>());
      expect((device as ProxyDevice).isSmartTrainer, isTrue);
    });

    test('an FE-C-only trainer surfaced by getSystemDevices stays eligible', () {
      final device = BluetoothDevice.fromScanResult(
        scan('Some FE-C Trainer', services: [FitnessBikeDefinition.FEC_BLE_SERVICE_UUID]),
      );
      expect(BluetoothDevice.isEligibleSystemDevice(device!), isTrue);
    });

    test('FE-C alongside Cycling Power under a power-meter brand name stays a trainer', () {
      final device = BluetoothDevice.fromScanResult(
        scan(
          'STAGES 123',
          services: [BleSensorSource.cyclingPowerServiceUuid, FitnessBikeDefinition.FEC_BLE_SERVICE_UUID],
        ),
      );
      expect(device, isA<ProxyDevice>());
    });
  });

  for (final web in [false, true]) {
    group('Van Rysel name-only advertisement (${web ? 'web' : 'native'})', () {
      setUp(() => BluetoothDevice.debugIsWeb = () => web);
      tearDown(() => BluetoothDevice.debugIsWeb = null);

      test('VANRYSEL-HT with no advertised services is a ProxyDevice', () {
        expect(BluetoothDevice.fromScanResult(scan('VANRYSEL-HT-0e66')), isA<ProxyDevice>());
      });

      test('the name match is case-insensitive', () {
        expect(BluetoothDevice.fromScanResult(scan('vanrysel-ht-0e66')), isA<ProxyDevice>());
      });

      test('a VANRYSEL-HT relaying heart rate is still the trainer, not a strap', () {
        final device = BluetoothDevice.fromScanResult(
          scan('VANRYSEL-HT-0e66', services: [BleSensorSource.heartRateServiceUuid]),
        );
        expect(device, isA<ProxyDevice>());
      });

      test('another Van Rysel product with no services is not claimed as a trainer', () {
        expect(BluetoothDevice.fromScanResult(scan('VANRYSEL-HRM-12')), isNull);
      });

      test('the name-only path resolves exactly like the Tacx Neo name-only path', () {
        final vanRysel = BluetoothDevice.fromScanResult(scan('VANRYSEL-HT-0e66')) as ProxyDevice;
        final neo = BluetoothDevice.fromScanResult(scan('Tacx Neo 2T 48844')) as ProxyDevice;
        // Nothing in the advertisement says "trainer service" yet, so both
        // default to Proxy until the rider picks a bridge mode; the control
        // protocol is resolved from the GATT database discovered on connect.
        expect(vanRysel.isSmartTrainer, neo.isSmartTrainer);
        expect(vanRysel.defaultRetrofitMode, neo.defaultRetrofitMode);
        expect(BluetoothDevice.isEligibleSystemDevice(vanRysel), BluetoothDevice.isEligibleSystemDevice(neo));
      });
    });
  }

  group('control protocol after service discovery', () {
    BleService fecService() => BleService(FitnessBikeDefinition.FEC_BLE_SERVICE_UUID, [
      BleCharacteristic('6e40fec2-b5a3-f393-e0a9-e50e24dcca9e', [CharacteristicProperty.notify], []),
      BleCharacteristic('6e40fec3-b5a3-f393-e0a9-e50e24dcca9e', [CharacteristicProperty.write], []),
    ]);
    BleService ftmsService() => BleService(FitnessBikeDefinition.FITNESS_MACHINE_SERVICE_UUID, [
      BleCharacteristic(
        '00002ad9-0000-1000-8000-00805f9b34fb',
        [CharacteristicProperty.write, CharacteristicProperty.indicate],
        [],
      ),
    ]);

    FitnessBikeDefinition definitionFor(List<BleService> discovered) => FitnessBikeDefinition(
      // The name-only scan result: the advertisement carried no services.
      connectedDevice: BleDevice(deviceId: 'vr', name: 'VANRYSEL-HT-0e66'),
      connectedDeviceServices: discovered,
      data: ValueNotifier<String>(''),
    );

    test('an FE-C-only GATT database is driven over FE-C', () {
      expect(definitionFor([fecService()]).autoControlProtocol, TrainerControlProtocol.fec);
    });

    test('a variant that also exposes an FTMS Control Point is driven over FTMS', () {
      expect(definitionFor([fecService(), ftmsService()]).autoControlProtocol, TrainerControlProtocol.ftms);
    });
  });
}
