import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:prop/transports/trainer_transport.dart';
import 'package:prop/utils/ble_connection_options.dart';
import 'package:universal_ble/universal_ble.dart';

/// [TrainerTransport] over Bluetooth LE, forwarding every call to
/// UniversalBle verbatim.
class BleTrainerTransport extends TrainerTransport {
  BleTrainerTransport(this.deviceId);

  final String deviceId;

  @override
  String get id => deviceId;

  @override
  Future<void> connect() async {
    await UniversalBle.connect(deviceId, platformConfig: bleConnectionPlatformConfig());
    if (!kIsWeb) {
      try {
        await UniversalBle.requestMtu(deviceId, 517);
      } catch (e) {
        // not critical, just log it
        debugPrint('Failed to request MTU: $e');
      }
    }
  }

  @override
  Future<List<BleService>> discoverServices() => UniversalBle.discoverServices(deviceId);

  @override
  Future<Uint8List> read(String service, String characteristic) => UniversalBle.read(deviceId, service, characteristic);

  @override
  Future<void> write(String service, String characteristic, Uint8List bytes, {bool withoutResponse = false}) =>
      UniversalBle.write(deviceId, service, characteristic, bytes, withoutResponse: withoutResponse);

  @override
  Future<void> subscribe(String service, String characteristic, {required bool indicate}) => indicate
      ? UniversalBle.subscribeIndications(deviceId, service, characteristic)
      : UniversalBle.subscribeNotifications(deviceId, service, characteristic);

  /// Empty on purpose: what a BLE trainer notifies reaches the app through the
  /// global `UniversalBle.onValueChange` handler, which routes it to the
  /// owning device. Emitting it here too would hand every value over twice.
  @override
  Stream<({String characteristic, Uint8List value})> get notifications => const Stream.empty();

  @override
  Future<void> disconnect() => UniversalBle.disconnect(deviceId);
}
