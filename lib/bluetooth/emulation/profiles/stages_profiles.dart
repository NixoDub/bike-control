import 'package:universal_ble/universal_ble.dart';

import '../../../services/sensors/ble_sensor_source.dart';
import '../emulated_ble_platform.dart';
import '../emulated_peripherals.dart';
import '../emulation_profile.dart';

// Stages smart bike: the button service (notify only) and the bike API
// service BikeControl never touches. Detection is by NAME.
const _buttonServiceUuid = '0c46be5f-9c22-48ff-ae0e-c6eae1a2f4e5';
const _buttonCharacteristicUuid = '0c46be60-9c22-48ff-ae0e-c6eae1a2f4e5';
const _apiServiceUuid = '0c46beaf-9c22-48ff-ae0e-c6eae1a2f4e5';
const _apiNotifyUuid = '0c46beb0-9c22-48ff-ae0e-c6eae1a2f4e5';
const _apiWriteUuid = '0c46beb1-9c22-48ff-ae0e-c6eae1a2f4e5';

/// The button characteristic, for tests that push frames straight through the
/// fake platform.
const stagesButtonCharacteristicUuid = _buttonCharacteristicUuid;

/// The bike API service and its characteristics, for tests asserting they are
/// left alone.
const stagesApiServiceUuid = _apiServiceUuid;
const stagesApiCharacteristicUuids = [_apiNotifyUuid, _apiWriteUuid];

/// One-hot button bits, as the bike sends them.
const _stagesButtons = <String, int>{
  'Left up': 0x0001,
  'Left down': 0x0002,
  'Left third': 0x0004,
  'Right up': 0x0008,
  'Right down': 0x0010,
  'Right third': 0x0020,
};

/// A button frame: `<type> 00 <bitmask u16 LE>`; the mid-press commit (type
/// 0x03) repeats the bitmask once more.
List<int> stagesButtonFrame(int type, int mask) => [
  type,
  0x00,
  mask & 0xff,
  (mask >> 8) & 0xff,
  if (type == 0x03) ...[mask & 0xff, (mask >> 8) & 0xff],
];

/// Held (streamed while the button is down), commit, release.
const stagesHeld = 0x01;
const stagesCommit = 0x03;
const stagesRelease = 0x04;

/// A Stages smart bike: one peripheral that is both a smart trainer (the FTMS +
/// Cycling Power GATT of [buildFtmsTrainer], plus CSC) and the host of its own
/// shift buttons, next to a bike API service.
///
/// [withTrainerServices] false leaves only the vendor services.
FakePeripheral buildStagesBike({
  String deviceId = 'emulated:stages-bike',
  String name = 'Stages Bike 0017',
  bool withTrainerServices = true,
  List<String> advertisedServices = const [],
}) {
  final peripheral = withTrainerServices
      ? buildFtmsTrainer(deviceId: deviceId, name: name)
      : FakePeripheral(deviceId: deviceId, name: name);
  peripheral.advertisedServices
    ..clear()
    ..addAll(advertisedServices);
  if (withTrainerServices) {
    peripheral.services.add(
      BleService(BleSensorSource.cscServiceUuid, [
        bleChar('00002a5b-0000-1000-8000-00805f9b34fb', [CharacteristicProperty.notify]),
      ]),
    );
  } else {
    peripheral.services.addAll(deviceInfoServices(peripheral));
  }
  peripheral.services.addAll([
    BleService(_buttonServiceUuid, [
      bleChar(_buttonCharacteristicUuid, [CharacteristicProperty.notify]),
    ]),
    BleService(_apiServiceUuid, [
      bleChar(_apiNotifyUuid, [CharacteristicProperty.notify]),
      bleChar(_apiWriteUuid, [CharacteristicProperty.writeWithoutResponse]),
    ]),
  ]);
  return peripheral;
}

final stagesSmartBikeProfile = EmulationProfile(
  name: 'Stages smart bike (trainer + buttons)',
  category: EmulationCategory.controller,
  build: buildStagesBike,
  inputs: (session) => [
    for (final entry in _stagesButtons.entries)
      EmulatedButton(
        entry.key,
        onDown: () {
          session.notify(_buttonCharacteristicUuid, stagesButtonFrame(stagesHeld, entry.value));
          session.notify(_buttonCharacteristicUuid, stagesButtonFrame(stagesCommit, entry.value));
        },
        onUp: () => session.notify(_buttonCharacteristicUuid, stagesButtonFrame(stagesRelease, entry.value)),
      ),
  ],
);
