import 'package:bike_control/bluetooth/devices/smart_bike/smart_bike_trainer.dart';
import 'package:bike_control/bluetooth/devices/zwift/constants.dart';
import 'package:bike_control/bluetooth/devices/zwift/zwift_ride.dart';
import 'package:bike_control/bluetooth/messages/notification.dart';
import 'package:bike_control/utils/core.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

/// A MUOV smart bike: one peripheral that is both an FTMS trainer and the host
/// of its hood buttons. The buttons come in over the Zwift Ride service
/// (FC82), so they are read like a Zwift Ride's. The bike advertises FTMS and
/// Cycling Power but no Zwift manufacturer data, so it is classified by name
/// as this controller; its trainer services are listed a second time as a
/// [SmartBikeTrainer] over the same link.
class MuovBike extends ZwiftRide with SmartBikeHost {
  MuovBike(super.scanResult) : super(isBeta: true);

  /// Not a Zwift Ride: its firmware has its own numbering, so it is never
  /// compared against the Ride's releases.
  @override
  String? get latestFirmwareVersion => null;

  @override
  bool get canVibrate => false;

  @override
  Set<String> get controllerServiceUuids => MuovBikeConstants.controllerServiceUuids;

  @override
  Set<String> get controllerCharacteristicUuids => {
    ZwiftConstants.ZWIFT_ASYNC_CHARACTERISTIC_UUID.toLowerCase(),
    ZwiftConstants.ZWIFT_SYNC_TX_CHARACTERISTIC_UUID.toLowerCase(),
  };

  @override
  Future<void> handleServices(List<BleService> services) async {
    final hasButtonService = services.any(
      (s) => s.uuid.toLowerCase() == ZwiftConstants.ZWIFT_RIDE_CUSTOM_SERVICE_UUID.toLowerCase(),
    );
    if (hasButtonService) await super.handleServices(services);

    await attachTrainer(services);

    if (!hasButtonService) {
      final missing = 'Service not found: ${ZwiftConstants.ZWIFT_RIDE_CUSTOM_SERVICE_UUID}';
      // Nothing to offer without the buttons unless the bike is a trainer.
      if (trainer == null) throw Exception(missing);
      core.connection.signalNotification(LogNotification('$this: $missing — trainer only'));
    }
  }

  @override
  Future<void> processCharacteristic(String characteristic, Uint8List bytes) async {
    if (!isControllerCharacteristic(characteristic)) {
      return forwardToTrainer(characteristic, bytes);
    }
    return super.processCharacteristic(characteristic, bytes);
  }
}

class MuovBikeConstants {
  /// The advertised name is `MUOV-<5 hex digits>`.
  static bool matchesName(String name) => name.toUpperCase().startsWith('MUOV');

  /// The button service and MUOV's own services (lower-case), as an nRF
  /// Connect scan of a MUOV bike listed them. BikeControl reads only the
  /// button service, and the trainer role mirrors none of them.
  static final Set<String> controllerServiceUuids = {
    ZwiftConstants.ZWIFT_RIDE_CUSTOM_SERVICE_UUID.toLowerCase(),
    '15580001-0574-4a8e-ba7c-ed79e9fe65ae',
    '14580001-0574-4a8e-ba7c-ed79e9fe65ae',
    'e5030001-1000-4368-a86e-333c1dbb09bf',
  };
}
