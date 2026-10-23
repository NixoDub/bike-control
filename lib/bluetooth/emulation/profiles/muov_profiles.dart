import 'package:universal_ble/universal_ble.dart';

import '../../../services/sensors/ble_sensor_source.dart';
import '../../devices/muov/muov_bike.dart';
import '../../devices/zwift/constants.dart';
import '../../devices/zwift/zwift_ride.dart' show RideButtonMask;
import '../emulated_ble_platform.dart';
import '../emulated_peripherals.dart';
import '../emulation_profile.dart';
import 'zwift_profiles.dart' show rideMaskInputs;

/// MUOV's own services. BikeControl never touches them; what they carry is
/// unknown.
final muovVendorServiceUuids = MuovBikeConstants.controllerServiceUuids
    .where((uuid) => uuid != ZwiftConstants.ZWIFT_RIDE_CUSTOM_SERVICE_UUID.toLowerCase())
    .toList();

/// A MUOV smart bike: the FTMS + Cycling Power GATT of [buildFtmsTrainer] plus
/// CSC, the Zwift Ride service (FC82) for its hood buttons and MUOV's own
/// services. It advertises FTMS + Cycling Power and FC82 service data, no
/// Zwift manufacturer data. Detection is by NAME.
///
/// [withButtonService] false leaves out the FC82 service.
FakePeripheral buildMuovBike({
  String deviceId = 'emulated:muov-bike',
  String name = 'MUOV-1A2B3',
  bool withButtonService = true,
}) {
  final peripheral = buildFtmsTrainer(deviceId: deviceId, name: name);
  peripheral.services.add(
    BleService(BleSensorSource.cscServiceUuid, [
      bleChar('00002a5b-0000-1000-8000-00805f9b34fb', [CharacteristicProperty.notify]),
    ]),
  );
  if (withButtonService) {
    peripheral.services.add(
      BleService(ZwiftConstants.ZWIFT_RIDE_CUSTOM_SERVICE_UUID.toLowerCase(), [
        bleChar(ZwiftConstants.ZWIFT_ASYNC_CHARACTERISTIC_UUID, [CharacteristicProperty.notify]),
        bleChar(ZwiftConstants.ZWIFT_SYNC_TX_CHARACTERISTIC_UUID, [CharacteristicProperty.indicate]),
        bleChar(ZwiftConstants.ZWIFT_SYNC_RX_CHARACTERISTIC_UUID, [
          CharacteristicProperty.write,
          CharacteristicProperty.writeWithoutResponse,
        ]),
      ]),
    );
  }
  for (final uuid in muovVendorServiceUuids) {
    peripheral.services.add(BleService(uuid, []));
  }
  return peripheral;
}

final muovBikeProfile = EmulationProfile(
  name: 'MUOV smart bike (trainer + buttons)',
  category: EmulationCategory.controller,
  build: buildMuovBike,
  onRegistered: (ble, peripheral) =>
      autoRespondToZwiftHandshake(ble, peripheral, startResponse: ZwiftConstants.RESPONSE_START_PLAY),
  inputs: (session) => rideMaskInputs(session, RideButtonMask.values),
);
