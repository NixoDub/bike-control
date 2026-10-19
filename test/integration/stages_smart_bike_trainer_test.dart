import 'dart:typed_data';

import 'package:bike_control/bluetooth/devices/smart_bike/smart_bike_trainer.dart';
import 'package:bike_control/bluetooth/devices/stages/stages_smart_bike.dart';
import 'package:bike_control/bluetooth/emulation/emulated_ble_platform.dart';
import 'package:bike_control/bluetooth/emulation/emulation_profile.dart';
import 'package:bike_control/bluetooth/emulation/profiles/stages_profiles.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:prop/emulators/dircon_emulator.dart' show RetrofitMode;

import 'harness/test_env.dart';

/// A Stages smart bike is ONE Bluetooth peripheral that is both a smart
/// trainer and the host of its shift buttons. Through the real Connection
/// class it must show up as a controller (buttons) AND as a trainer
/// (bridging), over a single BLE connection — and its bike API service is
/// never subscribed to, written to or mirrored.
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

  Future<StagesSmartBike> connectBike(FakePeripheral bike) async {
    env.ble.addPeripheral(bike);
    await core.connection.performScanning();
    await IntegrationEnv.waitFor(
      () => core.connection.devices.whereType<StagesSmartBike>().any((d) => d.isConnected),
      description: 'Stages bike connected as a controller',
    );
    return core.connection.devices.whereType<StagesSmartBike>().single;
  }

  Future<void> pressRightUp(FakePeripheral bike) async {
    stubActions.performedActions.clear();
    for (var i = 0; i < 12; i++) {
      env.ble.notify(bike.deviceId, stagesButtonCharacteristicUuid, stagesButtonFrame(stagesHeld, 0x0008));
    }
    env.ble.notify(bike.deviceId, stagesButtonCharacteristicUuid, stagesButtonFrame(stagesCommit, 0x0008));
    env.ble.notify(bike.deviceId, stagesButtonCharacteristicUuid, stagesButtonFrame(stagesRelease, 0x0008));
    await IntegrationEnv.waitFor(() => stubActions.performedActions.isNotEmpty, description: 'shift action');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      stubActions.performedActions.map((a) => a.button).where((b) => b == StagesSmartBikeButtons.rightUp),
      hasLength(1),
      reason: 'one press is one shift, however many held frames it streamed',
    );
  }

  test('a Stages bike exposing FTMS is both a controller and a trainer', () async {
    final bike = buildStagesBike();
    final controller = await connectBike(bike);

    await IntegrationEnv.waitFor(
      () => core.connection.proxyDevices.isNotEmpty,
      description: 'Stages bike listed as a trainer',
    );
    final trainer = core.connection.proxyDevices.single;
    expect(trainer, isA<SmartBikeTrainer>());
    expect((trainer as SmartBikeTrainer).host, controller);
    expect(controller.trainer, trainer);
    expect(trainer.device.deviceId, bike.deviceId);
    expect(trainer.name, 'Stages Bike 0017');
    expect(trainer.isSmartTrainer, isTrue);

    expect(core.connection.controllerDevices, [controller]);
    await pressRightUp(bike);

    expect(bike.connectAttempts, 1);
  });

  test('the button characteristic is subscribed; the bike API is left alone', () async {
    final bike = buildStagesBike();
    await connectBike(bike);
    await IntegrationEnv.waitFor(() => core.connection.proxyDevices.isNotEmpty, description: 'trainer listed');

    expect(bike.subscriptions, contains(stagesButtonCharacteristicUuid));
    for (final uuid in stagesApiCharacteristicUuids) {
      expect(bike.subscriptions, isNot(contains(uuid)));
      expect(bike.writes.where((w) => w.characteristic.toLowerCase() == uuid), isEmpty);
    }
  });

  test('the trainer role mirrors neither vendor service', () async {
    final bike = buildStagesBike();
    await connectBike(bike);
    await IntegrationEnv.waitFor(() => core.connection.proxyDevices.isNotEmpty, description: 'trainer listed');
    final trainer = core.connection.proxyDevices.single;

    final mirrored = (await trainer.discoverUpstreamServices()).map((s) => s.uuid.toLowerCase()).toList();
    expect(mirrored, isNot(contains(StagesSmartBikeConstants.BUTTON_SERVICE_UUID)));
    expect(mirrored, isNot(contains(stagesApiServiceUuid)));
    expect(mirrored, contains(FitnessBikeDefinition.FITNESS_MACHINE_SERVICE_UUID.toLowerCase()));
  });

  test('with trainer consent the bridge starts over the same BLE connection, buttons keep working', () async {
    await core.settings.setAutoConnect('Stages Bike 0017', true);
    final bike = buildStagesBike();
    final controller = await connectBike(bike);

    await IntegrationEnv.waitFor(
      () => core.connection.proxyDevices.isNotEmpty && core.connection.proxyDevices.single.isConnected,
      description: 'trainer role connected',
    );
    final trainer = core.connection.proxyDevices.single;
    await IntegrationEnv.waitFor(() => trainer.isStartedListenable.value, description: 'bridge started');

    expect(trainer.retrofitMode.value, RetrofitMode.wifi);
    trainer.fitnessBike!.subscribeToTrainer();
    await IntegrationEnv.waitFor(
      () => bike.subscriptions.contains(FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID.toLowerCase()),
      description: 'Indoor Bike Data subscription on the bike',
    );
    expect(bike.connectAttempts, 1);
    expect(controller.isConnected, isTrue);

    await pressRightUp(bike);
  });

  test('"No connection" on the trainer leaves the controller connected', () async {
    await core.settings.setAutoConnect('Stages Bike 0017', true);
    final bike = buildStagesBike();
    final controller = await connectBike(bike);
    await IntegrationEnv.waitFor(
      () => core.connection.proxyDevices.isNotEmpty && core.connection.proxyDevices.single.isStartedListenable.value,
      description: 'bridge started',
    );
    final trainer = core.connection.proxyDevices.single;

    await core.connection.disconnect(trainer, forget: false, persistForget: false, keepInList: true);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(trainer.isBridged, isFalse);
    expect(bike.isConnected, isTrue);
    expect(controller.isConnected, isTrue);
    await pressRightUp(bike);
  });

  test('when the bike drops, both roles go — no half-alive trainer', () async {
    await core.settings.setAutoConnect('Stages Bike 0017', true);
    final bike = buildStagesBike();
    await connectBike(bike);
    await IntegrationEnv.waitFor(
      () => core.connection.proxyDevices.isNotEmpty && core.connection.proxyDevices.single.isStartedListenable.value,
      description: 'bridge started',
    );
    final trainer = core.connection.proxyDevices.single;

    env.ble.removePeripheral(bike.deviceId);

    await IntegrationEnv.waitFor(
      () => core.connection.devices.whereType<StagesSmartBike>().isEmpty,
      description: 'controller removed',
    );
    await IntegrationEnv.waitFor(() => core.connection.proxyDevices.isEmpty, description: 'trainer removed');
    expect(trainer.isBridged, isFalse);
    expect(trainer.isConnected, isFalse);
  });

  test('disconnecting the controller takes the trainer role with it', () async {
    final bike = buildStagesBike();
    final controller = await connectBike(bike);
    await IntegrationEnv.waitFor(() => core.connection.proxyDevices.isNotEmpty, description: 'trainer listed');

    await core.connection.disconnect(controller, forget: true, persistForget: false);

    await IntegrationEnv.waitFor(() => core.connection.proxyDevices.isEmpty, description: 'trainer removed');
    expect(core.connection.devices.whereType<StagesSmartBike>(), isEmpty);
  });

  test('a Stages bike exposing no trainer service stays controller-only', () async {
    final bike = buildStagesBike(withTrainerServices: false);
    final controller = await connectBike(bike);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(core.connection.proxyDevices, isEmpty);
    expect(core.connection.devices, [controller]);
    await pressRightUp(bike);
  });

  test('button frames reaching the trainer role still press the controller buttons', () async {
    final bike = buildStagesBike();
    await connectBike(bike);
    await IntegrationEnv.waitFor(() => core.connection.proxyDevices.isNotEmpty, description: 'trainer listed');
    final trainer = core.connection.proxyDevices.single;

    for (final type in [stagesHeld, stagesRelease]) {
      await trainer.processCharacteristic(
        stagesButtonCharacteristicUuid,
        Uint8List.fromList(stagesButtonFrame(type, 0x0010)),
      );
    }
    await IntegrationEnv.waitFor(() => stubActions.performedActions.isNotEmpty, description: 'shift action');
    expect(stubActions.performedActions.map((a) => a.button), contains(StagesSmartBikeButtons.rightDown));
    expect(StagesSmartBikeButtons.rightDown.action, InGameAction.shiftDown);
  });

  test('the battery saver leaves a Stages bike connected while it carries the bridge', () async {
    await core.settings.setAutoConnect('Stages Bike 0017', true);
    final bike = buildStagesBike();
    final controller = await connectBike(bike);
    await IntegrationEnv.waitFor(
      () => core.connection.proxyDevices.isNotEmpty && core.connection.proxyDevices.single.isStartedListenable.value,
      description: 'bridge started',
    );
    final trainer = core.connection.proxyDevices.single;

    core.connection.debugTriggerInactivityTimeout();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(bike.isConnected, isTrue);
    expect(controller.isConnected, isTrue);
    expect(trainer.isBridged, isTrue);
  });

  test('the emulation profile: right down press performs shiftDown', () async {
    core.emulation.reset();
    core.emulation.attach(env.ble);
    core.emulation.start(stagesSmartBikeProfile);
    await core.connection.performScanning();
    await IntegrationEnv.waitFor(
      () => core.connection.devices.whereType<StagesSmartBike>().any((d) => d.isConnected),
      description: 'emulated Stages bike connected',
    );
    final session = core.emulation.sessionFor('emulated:stages-bike')!;
    final button = session.inputs.whereType<EmulatedButton>().firstWhere((b) => b.label == 'Right down');
    button.onDown();
    button.onUp();

    await IntegrationEnv.waitFor(() => stubActions.performedActions.isNotEmpty, description: 'shift action');
    expect(stubActions.performedActions.map((a) => a.button), contains(StagesSmartBikeButtons.rightDown));
    core.emulation.reset();
  });
}
