import 'package:bike_control/bluetooth/devices/proxy/proxy_device.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/apps/my_whoosh.dart';
import 'package:bike_control/utils/keymap/apps/rouvy.dart';
import 'package:bike_control/utils/keymap/apps/tacx.dart';
import 'package:bike_control/utils/keymap/apps/training_peaks.dart';
import 'package:bike_control/utils/keymap/apps/zwift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/dircon_emulator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

/// The name and bind behaviour the bridge picks per trainer app. What each
/// endpoint advertises is covered in `prop`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    core.settings.prefs = await SharedPreferences.getInstance();
    core.actionHandler = StubActions();
  });

  ProxyDevice deviceNamed(String? name) => ProxyDevice(BleDevice(deviceId: 'trainer', name: name));

  test('is the trainer name with a neutral suffix', () {
    core.settings.setTrainerApp(Rouvy());

    expect(deviceNamed('Wahoo KICKR 1EB7').bridgeAdvertisementName(), 'Wahoo KICKR 1EB7 - Bridge');
  });

  test('is neutral whatever the trainer is called', () {
    core.settings.setTrainerApp(Rouvy());

    for (final name in ['Wahoo KICKR 1EB7', 'BikeControl V2', 'bikecontrol', null, '']) {
      expect(
        deviceNamed(name).bridgeAdvertisementName()!.toLowerCase(),
        isNot(contains('bikecontrol')),
        reason: 'trainer named "$name"',
      );
    }
  });

  test('falls back to the bare suffix when the trainer has no usable name', () {
    core.settings.setTrainerApp(Rouvy());

    expect(deviceNamed(null).bridgeAdvertisementName(), 'Bridge');
    expect(deviceNamed('').bridgeAdvertisementName(), 'Bridge');
    expect(deviceNamed('BikeControl V2').bridgeAdvertisementName(), 'Bridge');
  });

  group('Zwift', () {
    setUp(() => core.settings.setTrainerApp(Zwift()));

    test('is BikeControl plus the trainer\'s trailing identifier', () {
      expect(deviceNamed('KICKR CORE 73D3').bridgeAdvertisementName(), 'BikeControl 73D3');
      expect(deviceNamed('Wahoo KICKR 1EB7').bridgeAdvertisementName(), 'BikeControl 1EB7');
    });

    test('is plain BikeControl when the trainer has no name', () {
      expect(deviceNamed(null).bridgeAdvertisementName(), 'BikeControl');
      expect(deviceNamed('').bridgeAdvertisementName(), 'BikeControl');
      expect(deviceNamed('   ').bridgeAdvertisementName(), 'BikeControl');
    });

    test('is plain BikeControl when the name has no trailing identifier', () {
      expect(deviceNamed('KICKR').bridgeAdvertisementName(), 'BikeControl');
      expect(deviceNamed('Wahoo KICKR').bridgeAdvertisementName(), 'BikeControl');
    });

    test('neither contains the trainer name nor is contained in it', () {
      for (final name in [
        'KICKR CORE 73D3',
        'Wahoo KICKR 1EB7',
        'KICKR',
        '73D3',
        'BikeControl',
        'bikecontrol',
        'BikeControl 73D3',
        'BikeControl V2',
        'My BikeControl Bridge 2',
      ]) {
        final advertised = deviceNamed(name).bridgeAdvertisementName()!.toLowerCase();
        final trainer = name.toLowerCase();
        expect(advertised, isNot(contains(trainer)), reason: 'trainer named "$name"');
        expect(trainer, isNot(contains(advertised)), reason: 'trainer named "$name"');
      }
    });

    test('a trainer named like BikeControl gets a name that does not overlap', () {
      expect(deviceNamed('BikeControl').bridgeAdvertisementName(), 'Bridge');
      expect(deviceNamed('BikeControl 73D3').bridgeAdvertisementName(), 'Bridge');
    });
  });

  test('is not imposed on any other trainer app', () {
    for (final app in [MyWhoosh(), TrainingPeaks(), Tacx()]) {
      core.settings.setTrainerApp(app);
      expect(deviceNamed('Wahoo KICKR 1EB7').bridgeAdvertisementName(), isNull, reason: app.name);
    }
  });

  test('MyWhoosh keeps the trainer name with the BikeControl suffix', () {
    core.settings.setTrainerApp(MyWhoosh());
    final device = deviceNamed('KICKR CORE 73D3');
    final emulator = DirconEmulator()
      ..deviceName = (() => 'KICKR CORE 73D3')
      ..advertisementNameOverride = device.bridgeAdvertisementName;

    expect(emulator.advertisementName, 'KICKR CORE 73D3 - BikeControl');
  });

  test('the advertised name follows the trainer app as it changes', () {
    final device = deviceNamed('KICKR CORE 73D3');
    final emulator = DirconEmulator()
      ..deviceName = (() => 'KICKR CORE 73D3')
      ..advertisementNameOverride = device.bridgeAdvertisementName;

    core.settings.setTrainerApp(Zwift());
    expect(emulator.advertisementName, 'BikeControl 73D3');

    core.settings.setTrainerApp(Rouvy());
    expect(emulator.advertisementName, 'KICKR CORE 73D3 - Bridge');

    core.settings.setTrainerApp(MyWhoosh());
    expect(emulator.advertisementName, 'KICKR CORE 73D3 - BikeControl');

    core.settings.setTrainerApp(Zwift());
    expect(emulator.advertisementName, 'BikeControl 73D3');
  });

  test('binds IPv4-only for Rouvy and dual-stack for everyone else', () {
    core.settings.setTrainerApp(Rouvy());
    expect(deviceNamed('Wahoo KICKR 1EB7').rouvyNeedsIPv4(), isTrue);

    core.settings.setTrainerApp(Zwift());
    expect(deviceNamed('Wahoo KICKR 1EB7').rouvyNeedsIPv4(), isFalse);
  });
}
