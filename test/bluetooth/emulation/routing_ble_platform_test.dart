import 'dart:typed_data';

import 'package:bike_control/bluetooth/emulation/emulated_ble_platform.dart';
import 'package:bike_control/bluetooth/emulation/routing_ble_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

class _ThrowingScanPlatform extends FakeUniversalBlePlatform {
  @override
  Future<void> startScan({ScanFilter? scanFilter, PlatformConfig? platformConfig}) async {
    throw StateError('radio off');
  }
}

// A `real` double whose connect() throws a message distinct from
// FakeUniversalBlePlatform's own `_require` error, so a test can tell which
// side actually handled a call instead of both sides looking identical.
class _UnreachableRealPlatform extends FakeUniversalBlePlatform {
  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    throw StateError('real must not be reached for emulated: ids');
  }
}

void main() {
  late FakeUniversalBlePlatform real;
  late FakeUniversalBlePlatform fake;
  late RoutingBlePlatform routing;

  FakePeripheral peripheral(String id) => FakePeripheral(
    deviceId: id,
    name: 'P $id',
    services: [
      BleService('0000180f-0000-1000-8000-00805f9b34fb', const []),
    ],
  );

  setUp(() {
    real = FakeUniversalBlePlatform();
    fake = FakeUniversalBlePlatform();
    routing = RoutingBlePlatform(real: real, fake: fake);
  });

  test('dispatches per-device calls to the fake when the id is an emulated peripheral', () async {
    real.addPeripheral(peripheral('real:1'));
    fake.addPeripheral(peripheral('emulated:1'));

    await routing.connect('emulated:1');
    await routing.connect('real:1');

    expect(fake.peripherals['emulated:1']!.isConnected, isTrue);
    expect(real.peripherals['real:1']!.isConnected, isTrue);
    expect(real.peripherals.containsKey('emulated:1'), isFalse);

    expect(await routing.discoverServices('emulated:1', false), hasLength(1));
  });

  test('forwards scan results from both children through the routing instance', () async {
    final seen = <String>[];
    routing.onScanResultUpdate = (device) => seen.add(device.deviceId);

    await routing.startScan();
    real.addPeripheral(peripheral('real:1'));
    fake.addPeripheral(peripheral('emulated:1'));

    expect(seen, containsAll(['real:1', 'emulated:1']));
  });

  test('forwards connection events into the routing connectionStream', () async {
    fake.addPeripheral(peripheral('emulated:1'));
    final events = <bool>[];
    final sub = routing.connectionStream('emulated:1').listen(events.add);

    await routing.connect('emulated:1');
    await Future<void>.delayed(Duration.zero);

    expect(events, [true]);
    await sub.cancel();
  });

  test('forwards characteristic notifications to the routing onValueChange', () async {
    fake.addPeripheral(peripheral('emulated:1'));
    Uint8List? received;
    routing.onValueChange = (change) => received = change.value;

    fake.notify('emulated:1', '00002a00-0000-1000-8000-00805f9b34fb', const [1, 2, 3]);

    expect(received, Uint8List.fromList(const [1, 2, 3]));
  });

  test('startScan survives a dead real radio when emulated peripherals exist', () async {
    final throwing = _ThrowingScanPlatform();
    final routing2 = RoutingBlePlatform(real: throwing, fake: fake);

    fake.addPeripheral(peripheral('emulated:1'));
    await routing2.startScan(); // must not throw
  });

  test('startScan rethrows a real-radio failure when no emulated peripherals exist', () async {
    final throwing = _ThrowingScanPlatform();
    final routing2 = RoutingBlePlatform(real: throwing, fake: FakeUniversalBlePlatform());

    expect(routing2.startScan(), throwsStateError);
  });

  test('routes a stray call for an unregistered emulated: id to the fake, not the real stack', () async {
    // Simulates a post-forget stray call: the id was never (re-)registered
    // on either side. `real` is a double that throws a distinguishable error
    // from its connect(), so if routing fell back to `real` on the
    // containsKey miss, the assertion below would fail on the wrong message.
    final unreachableReal = _UnreachableRealPlatform();
    final routing2 = RoutingBlePlatform(real: unreachableReal, fake: FakeUniversalBlePlatform());

    await expectLater(
      routing2.connect('emulated:gone'),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'FakePeripheral emulated:gone is not registered'),
      ),
    );
  });

  test('passes the connect platformConfig through to the child platform', () async {
    real.addPeripheral(peripheral('aa:bb:cc:dd:ee:ff'));
    final config = ConnectionPlatformConfig(
      apple: AppleConnectionOptions(notifyOnConnection: true, notifyOnDisconnection: true, notifyOnNotification: true),
    );

    await routing.connect('aa:bb:cc:dd:ee:ff', platformConfig: config);

    expect(real.lastConnectPlatformConfig, same(config));
  });

  test('forwards connection error details (errorCode / nativeErrorCode) from a child', () async {
    fake.addPeripheral(peripheral('emulated:1'));
    BleConnectionChange? change;
    routing.onConnectionChange = (c) => change = c;

    fake.updateConnection('emulated:1', false, 'link lost', UniversalBleErrorCode.deviceDisconnected, 0x13);

    expect(change, isNotNull);
    expect(change!.deviceId, 'emulated:1');
    expect(change!.isConnected, isFalse);
    expect(change!.error, 'link lost');
    expect(change!.errorCode, UniversalBleErrorCode.deviceDisconnected);
    expect(change!.nativeErrorCode, 0x13);
  });

  test('emits canonical lower-case ids and still routes them back to the registered peripheral', () async {
    // universal_ble 3 canonicalises every emitted id; a peripheral registered
    // with an upper-case address must still be reachable by that canonical id.
    real.addPeripheral(peripheral('AA:BB:CC:DD:EE:FF'));
    final seen = <String>[];
    routing.onScanResultUpdate = (device) => seen.add(device.deviceId);

    await routing.startScan();
    expect(seen, contains('aa:bb:cc:dd:ee:ff'));

    await routing.connect('aa:bb:cc:dd:ee:ff');
    expect(real.peripherals['AA:BB:CC:DD:EE:FF']!.isConnected, isTrue);
  });

  test('routes descriptor reads and writes to the owning child', () async {
    final p = peripheral('emulated:1');
    p.descriptorValues['00002902-0000-1000-8000-00805f9b34fb'] = Uint8List.fromList(const [1, 0]);
    fake.addPeripheral(p);

    final value = await routing.readDescriptorValue(
      'emulated:1',
      '0000180f-0000-1000-8000-00805f9b34fb',
      '00002a19-0000-1000-8000-00805f9b34fb',
      '00002902-0000-1000-8000-00805f9b34fb',
    );
    expect(value, Uint8List.fromList(const [1, 0]));

    await routing.writeDescriptorValue(
      'emulated:1',
      '0000180f-0000-1000-8000-00805f9b34fb',
      '00002a19-0000-1000-8000-00805f9b34fb',
      '00002902-0000-1000-8000-00805f9b34fb',
      Uint8List.fromList(const [0, 0]),
    );
    expect(p.descriptorValues['00002902-0000-1000-8000-00805f9b34fb'], Uint8List.fromList(const [0, 0]));
  });
}
