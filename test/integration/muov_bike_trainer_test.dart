import 'dart:typed_data';

import 'package:bike_control/bluetooth/devices/muov/muov_bike.dart';
import 'package:bike_control/bluetooth/devices/smart_bike/smart_bike_trainer.dart';
import 'package:bike_control/bluetooth/devices/zwift/constants.dart';
import 'package:bike_control/bluetooth/devices/zwift/zwift_ride.dart' show RideButtonMask;
import 'package:bike_control/bluetooth/emulation/emulated_ble_platform.dart';
import 'package:bike_control/bluetooth/emulation/emulated_peripherals.dart';
import 'package:bike_control/bluetooth/emulation/profiles/muov_profiles.dart';
import 'package:bike_control/bluetooth/messages/notification.dart';
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:prop/prop.dart' show LogLevel;

import 'harness/test_env.dart';

/// A MUOV smart bike is ONE Bluetooth peripheral that is both an FTMS trainer
/// and the host of its hood buttons, which it sends like a Zwift Ride over
/// the FC82 service. Through the real Connection class it must show up as a
/// controller (buttons) AND as a trainer (bridging), over a single BLE
/// connection.
Future<void> main() async {
  final env = await IntegrationEnv.setUp();
  late StubActions stubActions;

  core.connection.initialize();

  setUp(() async {
    await env.resetState();
    stubActions = StubActions();
    core.actionHandler = stubActions;
  });

  tearDown(() async {
    await env.resetConnection();
  });

  Future<MuovBike> connectBike(FakePeripheral bike) async {
    env.ble.addPeripheral(bike);
    await core.connection.performScanning();
    await IntegrationEnv.waitFor(
      () => core.connection.devices.whereType<MuovBike>().any((d) => d.isConnected),
      description: 'MUOV connected as a controller',
    );
    return core.connection.devices.whereType<MuovBike>().single;
  }

  Future<void> press(FakePeripheral bike, RideButtonMask mask, ControllerButton expected) async {
    stubActions.performedActions.clear();
    env.ble.notify(
      bike.deviceId,
      ZwiftConstants.ZWIFT_ASYNC_CHARACTERISTIC_UUID,
      zwiftRideNotification(pressed: [mask]),
    );
    env.ble.notify(bike.deviceId, ZwiftConstants.ZWIFT_ASYNC_CHARACTERISTIC_UUID, zwiftRideNotification());
    await IntegrationEnv.waitFor(() => stubActions.performedActions.isNotEmpty, description: 'button action');
    expect(stubActions.performedActions.map((a) => a.button), contains(expected));
  }

  test('a MUOV exposing FTMS is both a controller and a trainer', () async {
    final bike = buildMuovBike();
    final controller = await connectBike(bike);

    await IntegrationEnv.waitFor(
      () => core.connection.proxyDevices.isNotEmpty,
      description: 'MUOV listed as a trainer',
    );
    final trainer = core.connection.proxyDevices.single;
    expect(trainer, isA<SmartBikeTrainer>());
    expect((trainer as SmartBikeTrainer).host, controller);
    expect(controller.trainer, trainer);
    expect(trainer.name, 'MUOV-1A2B3');
    expect(trainer.isSmartTrainer, isTrue);
    expect(core.connection.controllerDevices, [controller]);

    await press(bike, RideButtonMask.LEFT_BTN, ZwiftButtons.navigationLeft);
    expect(bike.connectAttempts, 1);
  });

  test('the Zwift button characteristics are subscribed and RideOn is sent', () async {
    final bike = buildMuovBike();
    await connectBike(bike);

    expect(bike.subscriptions, contains(ZwiftConstants.ZWIFT_ASYNC_CHARACTERISTIC_UUID.toLowerCase()));
    expect(
      bike.writes.where(
        (w) => w.characteristic.toLowerCase() == ZwiftConstants.ZWIFT_SYNC_RX_CHARACTERISTIC_UUID.toLowerCase(),
      ),
      isNotEmpty,
    );
  });

  test('the trainer role mirrors neither the button service nor the MUOV services', () async {
    final bike = buildMuovBike();
    await connectBike(bike);
    await IntegrationEnv.waitFor(() => core.connection.proxyDevices.isNotEmpty, description: 'trainer listed');
    final trainer = core.connection.proxyDevices.single;

    final mirrored = (await trainer.discoverUpstreamServices()).map((s) => s.uuid.toLowerCase()).toList();
    expect(mirrored, isNot(contains(ZwiftConstants.ZWIFT_RIDE_CUSTOM_SERVICE_UUID.toLowerCase())));
    for (final uuid in muovVendorServiceUuids) {
      expect(mirrored, isNot(contains(uuid)));
    }
    expect(mirrored, contains(FitnessBikeDefinition.FITNESS_MACHINE_SERVICE_UUID.toLowerCase()));
  });

  test('button frames reaching the trainer role still press the controller buttons', () async {
    final bike = buildMuovBike();
    await connectBike(bike);
    await IntegrationEnv.waitFor(() => core.connection.proxyDevices.isNotEmpty, description: 'trainer listed');
    final trainer = core.connection.proxyDevices.single;

    for (final frame in [
      zwiftRideNotification(pressed: [RideButtonMask.RIGHT_BTN]),
      zwiftRideNotification(),
    ]) {
      await trainer.processCharacteristic(ZwiftConstants.ZWIFT_ASYNC_CHARACTERISTIC_UUID, Uint8List.fromList(frame));
    }
    await IntegrationEnv.waitFor(() => stubActions.performedActions.isNotEmpty, description: 'button action');
    expect(stubActions.performedActions.map((a) => a.button), contains(ZwiftButtons.navigationRight));
  });

  test('a MUOV without the button service stays a trainer and asks for no Zwift firmware update', () async {
    final alerts = <AlertNotification>[];
    final sub = core.connection.actionStream.listen((n) {
      if (n is AlertNotification) alerts.add(n);
    });
    addTearDown(sub.cancel);

    final bike = buildMuovBike(withButtonService: false);
    final controller = await connectBike(bike);
    await IntegrationEnv.waitFor(() => core.connection.proxyDevices.isNotEmpty, description: 'trainer listed');

    expect(controller.isConnected, isTrue);
    expect(alerts.where((a) => a.buttonTitle == AppLocalizations.current.zwiftCompanionApp), isEmpty);
    expect(alerts.where((a) => a.level == LogLevel.LOGLEVEL_ERROR), isEmpty);
  });

  test('when the bike drops, both roles go', () async {
    final bike = buildMuovBike();
    await connectBike(bike);
    await IntegrationEnv.waitFor(() => core.connection.proxyDevices.isNotEmpty, description: 'trainer listed');

    env.ble.removePeripheral(bike.deviceId);

    await IntegrationEnv.waitFor(
      () => core.connection.devices.whereType<MuovBike>().isEmpty,
      description: 'controller removed',
    );
    await IntegrationEnv.waitFor(() => core.connection.proxyDevices.isEmpty, description: 'trainer removed');
  });
}
