import 'package:bike_control/bluetooth/devices/openbikecontrol/obc_ble_emulator.dart';
import 'package:bike_control/bluetooth/devices/openbikecontrol/openbikecontrol_device.dart';
import 'package:bike_control/bluetooth/peripheral_server.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../integration/harness/test_env.dart';

class _AdvertisingCall {
  _AdvertisingCall(this.services, this.localName, this.servicesInScanResponse);
  final List<String> services;
  final String? localName;
  final bool servicesInScanResponse;
}

class _RecordingPeripheralServer extends PeripheralServer {
  final calls = <_AdvertisingCall>[];

  @override
  Future<void> startAdvertising({
    required List<String> services,
    String? localName,
    bool servicesInScanResponse = false,
  }) async {
    calls.add(_AdvertisingCall(services, localName, servicesInScanResponse));
  }
}

Future<void> main() async {
  await IntegrationEnv.setUp();

  test('OBC advertisement moves the 128-bit service UUID to the scan response', () async {
    final server = _RecordingPeripheralServer();
    final emulator = OpenBikeControlBluetoothEmulator(server: server);

    await emulator.startServiceAdvertising();

    expect(server.calls, hasLength(1));
    final call = server.calls.single;
    expect(call.services, [OpenBikeControlConstants.SERVICE_UUID]);
    expect(call.localName, 'BikeControl');
    // Flags (3) + name AD (2 + 11) + 128-bit UUID AD (18) = 34 bytes > 31:
    // Android rejects the primary advertisement with "Data too large" unless
    // the UUID goes into the scan response.
    expect(call.servicesInScanResponse, isTrue);
  });

  test('primary advertisement without the UUID fits in 31 bytes', () {
    const flags = 3;
    final nameAd = 2 + 'BikeControl'.length;
    const uuid128Ad = 2 + 16;
    expect(flags + nameAd + uuid128Ad, greaterThan(31));
    expect(flags + nameAd, lessThanOrEqualTo(31));
    expect(uuid128Ad, lessThanOrEqualTo(31));
  });
}
