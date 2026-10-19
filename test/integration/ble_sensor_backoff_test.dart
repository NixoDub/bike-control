import 'dart:async';

import 'package:bike_control/bluetooth/devices/sensors/ble_heart_rate_device.dart';
import 'package:bike_control/bluetooth/emulation/emulated_ble_platform.dart';
import 'package:bike_control/bluetooth/messages/notification.dart';
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/services/sensors/ble_sensor_source.dart';
import 'package:bike_control/utils/actions/base_actions.dart';
import 'package:bike_control/utils/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'harness/test_env.dart';

/// A BLE sensor (heart rate strap, power meter, cadence sensor) whose connect
/// fails deterministically must stop being retried. On iOS every app shares
/// one link to the strap, so an endless connect/drop loop keeps knocking the
/// strap off the trainer app too. Drives the REAL Connection; only the BLE
/// platform is fake.
Future<void> main() async {
  final env = await IntegrationEnv.setUp();
  final notifications = <BaseNotification>[];
  late StreamSubscription<BaseNotification> notificationSub;
  Timer? advTimer;

  core.connection.initialize();

  const strapId = 'hr-strap-backoff';

  FakePeripheral heartRateStrap() => FakePeripheral(
    deviceId: strapId,
    name: 'HRM 1234',
    advertisedServices: [BleSensorSource.heartRateServiceUuid],
    services: [
      BleService(BleSensorSource.heartRateServiceUuid, [
        BleCharacteristic(BleSensorSource.heartRateMeasurementUuid, [CharacteristicProperty.notify], const []),
      ]),
    ],
  );

  /// Re-emit the advertisement continuously like a real strap — the retry
  /// loop is driven by rediscovery.
  void startAdvertising(FakePeripheral peripheral) {
    advTimer?.cancel();
    advTimer = Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => env.ble.updateScanResult(peripheral.scanResult),
    );
  }

  setUp(() async {
    await env.resetState();
    // The rider picked this strap before: it has auto-connect consent.
    await core.settings.setSensorAutoConnect(strapId, true);
    core.actionHandler = StubActions();
    notifications.clear();
    notificationSub = core.connection.actionStream.listen(notifications.add);
    core.connection.autoConnectBackoffCooldown = const Duration(seconds: 30);
  });

  tearDown(() async {
    advTimer?.cancel();
    await notificationSub.cancel();
    await env.resetConnection();
  });

  List<AlertNotification> gaveUpAlerts() => notifications
      .whereType<AlertNotification>()
      .where((n) => n.alertMessage.contains(AppLocalizations.current.connectionGaveUpAfterAttempts('HRM 1234')))
      .toList();

  BleHeartRateDevice strapDevice() => core.connection.devices.whereType<BleHeartRateDevice>().first;

  test('a strap whose connect keeps failing gives up after three attempts', () async {
    final strap = heartRateStrap();
    strap.connectError = Exception('Encryption is insufficient');
    env.ble.addPeripheral(strap);
    startAdvertising(strap);
    await core.connection.performScanning();

    await IntegrationEnv.waitFor(() => gaveUpAlerts().isNotEmpty, description: 'give-up alert');
    expect(strap.connectAttempts, 3);
    expect(core.connection.isAutoReconnectSuppressed(strapDevice()), isTrue);

    // Suppressed while the strap keeps advertising: no further attempts.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(strap.connectAttempts, 3);
    expect(gaveUpAlerts().length, 1);
  });

  test('a strap that connects but drops right away gives up after three drops', () async {
    final strap = heartRateStrap();
    env.ble.addPeripheral(strap);
    startAdvertising(strap);
    await core.connection.performScanning();

    for (var i = 0; i < 3; i++) {
      await IntegrationEnv.waitFor(
        () => strap.isConnected && core.connection.devices.whereType<BleHeartRateDevice>().any((d) => d.isConnected),
        description: 'connect #${i + 1}',
      );
      env.ble.dropConnection(strap.deviceId);
      await IntegrationEnv.waitFor(
        () => !core.connection.devices.whereType<BleHeartRateDevice>().any((d) => d.isConnected),
        description: 'drop #${i + 1}',
      );
    }

    await IntegrationEnv.waitFor(() => gaveUpAlerts().isNotEmpty, description: 'give-up alert');
    final attempts = strap.connectAttempts;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(strap.connectAttempts, attempts);
  });

  test('picking the strap again after a give-up starts a fresh attempt budget', () async {
    final strap = heartRateStrap();
    strap.connectError = Exception('Encryption is insufficient');
    env.ble.addPeripheral(strap);
    startAdvertising(strap);
    await core.connection.performScanning();

    await IntegrationEnv.waitFor(() => gaveUpAlerts().isNotEmpty, description: 'give-up alert');
    expect(strap.connectAttempts, 3);

    // The rider selects the strap again (SensorQuantitySelector ->
    // connectDevice) while it is still failing.
    await expectLater(core.connection.connectDevice(strapDevice()), throwsA(anything));
    expect(strap.connectAttempts, 4);

    // A fresh streak: rediscovery gets the full three automatic attempts
    // again (the rider's own attempt reports its failure to the caller and
    // is not part of the auto-connect streak), then backs off again.
    await IntegrationEnv.waitFor(
      () => strap.connectAttempts >= 7,
      description: 'fresh three-attempt budget',
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(strap.connectAttempts, 7);
  });

  test('picking the strap again connects it once it is free', () async {
    final strap = heartRateStrap();
    strap.connectError = Exception('Encryption is insufficient');
    env.ble.addPeripheral(strap);
    startAdvertising(strap);
    await core.connection.performScanning();

    await IntegrationEnv.waitFor(() => gaveUpAlerts().isNotEmpty, description: 'give-up alert');

    strap.connectError = null;
    await core.connection.connectDevice(strapDevice());
    await IntegrationEnv.waitFor(
      () => core.connection.devices.whereType<BleHeartRateDevice>().any((d) => d.isConnected),
      description: 'rider-initiated connect',
    );
  });
}
