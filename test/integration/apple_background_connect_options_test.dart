import 'dart:async';

import 'package:bike_control/bluetooth/devices/zwift/zwift_click.dart';
import 'package:bike_control/bluetooth/emulation/emulated_peripherals.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/keymap/apps/zwift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'harness/test_env.dart';

/// On iOS/macOS a backgrounded BikeControl must be woken by CoreBluetooth for
/// connection, disconnection and notification events, otherwise controllers
/// and trainers go quiet as soon as the trainer app is in front. That is
/// opted into per connect via AppleConnectionOptions — so EVERY connect the
/// app makes (first connect, retries, trainer connects) must carry all three.
Future<void> main() async {
  final env = await IntegrationEnv.setUp();

  core.connection.initialize();

  setUp(() async {
    await env.resetState();
    final stubActions = StubActions();
    stubActions.supportedApp = Zwift();
    core.actionHandler = stubActions;
    core.connection.connectRetryBaseDelay = const Duration(milliseconds: 200);
    env.ble.connectPlatformConfigs.clear();
  });

  tearDown(() async {
    await env.resetConnection();
  });

  Matcher wakesTheAppInBackground() => isA<ConnectionPlatformConfig>().having(
    (c) => c.apple,
    'apple',
    isA<AppleConnectionOptions>()
        .having((a) => a.notifyOnConnection, 'notifyOnConnection', isTrue)
        .having((a) => a.notifyOnDisconnection, 'notifyOnDisconnection', isTrue)
        .having((a) => a.notifyOnNotification, 'notifyOnNotification', isTrue),
  );

  test('a controller connect asks CoreBluetooth to wake the app in the background', () async {
    final click = buildZwiftClick();
    autoRespondToZwiftHandshake(env.ble, click);
    env.ble.addPeripheral(click);

    await core.connection.performScanning();
    await IntegrationEnv.waitFor(
      () => core.connection.devices.whereType<ZwiftClick>().any((d) => d.isConnected),
      description: 'controller connected',
    );

    expect(env.ble.connectPlatformConfigs, isNotEmpty);
    expect(env.ble.connectPlatformConfigs, everyElement(wakesTheAppInBackground()));
  });

  test('a connect retry keeps the background wake options', () async {
    final click = buildZwiftClick();
    autoRespondToZwiftHandshake(env.ble, click);
    click.connectError = TimeoutException('Future not completed', const Duration(minutes: 1));
    click.connectErrorDeliversDisconnect = false;
    env.ble.addPeripheral(click);

    await core.connection.performScanning();
    await IntegrationEnv.waitFor(() => click.connectAttempts >= 1, description: 'first connect attempt');
    click.connectError = null;
    await IntegrationEnv.waitFor(
      () => core.connection.devices.whereType<ZwiftClick>().any((d) => d.isConnected),
      description: 'retry connected',
    );

    expect(env.ble.connectPlatformConfigs.length, greaterThanOrEqualTo(2));
    expect(env.ble.connectPlatformConfigs, everyElement(wakesTheAppInBackground()));
  });

  test('a trainer connect asks CoreBluetooth to wake the app in the background', () async {
    final trainer = buildFtmsTrainer();
    env.ble.addPeripheral(trainer);
    await core.settings.setAutoConnect('KICKR CORE 1234', true);

    await core.connection.performScanning();
    await IntegrationEnv.waitFor(
      () => core.connection.proxyDevices.isNotEmpty && core.connection.proxyDevices.single.isConnected,
      description: 'trainer auto-connected',
    );

    expect(trainer.connectAttempts, greaterThanOrEqualTo(1));
    expect(env.ble.connectPlatformConfigs, isNotEmpty);
    expect(env.ble.connectPlatformConfigs, everyElement(wakesTheAppInBackground()));
  });
}
