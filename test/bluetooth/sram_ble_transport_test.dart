import 'dart:async';
import 'dart:typed_data';

import 'package:bike_control/bluetooth/devices/sram/sram_ble_transport.dart';
import 'package:bike_control/bluetooth/emulation/emulated_ble_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

BleService _svc(String uuid, List<BleCharacteristic> chars) => BleService(uuid, chars);

BleCharacteristic _char(String uuid, List<CharacteristicProperty> props) =>
    BleCharacteristic(uuid, props, const []);

/// A BLE platform whose GATT calls fail like a wedged link: they throw the
/// same TimeoutException universal_ble's command queue raises after 10 s.
class _WedgedPlatform extends FakeUniversalBlePlatform {
  _WedgedPlatform(this.error);
  final Object error;

  @override
  Future<Uint8List> readValue(String deviceId, String service, String characteristic, {Duration? timeout}) async =>
      throw error;

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async =>
      throw error;

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async =>
      throw error;
}

void main() {
  test('lists read+write characteristics only', () {
    final services = [
      _svc('d905ee51-90aa-4c7c-b036-1e01fb8eb7ee', [
        _char('d9050028-90aa-4c7c-b036-1e01fb8eb7ee',
            [CharacteristicProperty.read, CharacteristicProperty.write]),
        _char('d9050054-90aa-4c7c-b036-1e01fb8eb7ee', [CharacteristicProperty.notify]),
      ]),
    ];
    final t = SramBleTransport('dev1', services);
    expect(t.readWriteCharacteristics(), ['d9050028-90aa-4c7c-b036-1e01fb8eb7ee']);
  });

  test('notifications stream delivers pumped values', () async {
    final t = SramBleTransport('dev1', const []);
    final char = 'd905ee52-90aa-4c7c-b036-1e01fb8eb7ee';
    final future = t.notifications(char).first;
    t.onNotification(char, Uint8List.fromList([1, 2, 3]));
    expect(await future, [1, 2, 3]);
  });

  group('transport errors name the operation and characteristic', () {
    const svc = 'd905ee51-90aa-4c7c-b036-1e01fb8eb7ee';
    const char = 'd905ee53-90aa-4c7c-b036-1e01fb8eb7ee';
    final services = [
      _svc(svc, [
        _char(char, [CharacteristicProperty.read, CharacteristicProperty.write, CharacteristicProperty.notify]),
      ]),
    ];
    final timeout = TimeoutException('Future not completed', const Duration(seconds: 10));

    setUp(() => UniversalBle.setInstance(_WedgedPlatform(timeout)));

    test('read timeout stays a TimeoutException and says what hung', () async {
      final t = SramBleTransport('dev1', services);
      await expectLater(
        t.read(char.toUpperCase()),
        throwsA(
          isA<TimeoutException>()
              .having((e) => e.duration, 'duration', const Duration(seconds: 10))
              .having((e) => e.toString(), 'message', contains('(read $char)')),
        ),
      );
    });

    test('write timeout says what hung', () async {
      final t = SramBleTransport('dev1', services);
      await expectLater(
        t.write(char, Uint8List.fromList([1])),
        throwsA(isA<TimeoutException>().having((e) => e.toString(), 'message', contains('(write $char)'))),
      );
    });

    test('subscribe timeout says what hung', () async {
      final t = SramBleTransport('dev1', services);
      await expectLater(
        t.subscribe(char),
        throwsA(isA<TimeoutException>().having((e) => e.toString(), 'message', contains('(subscribe $char)'))),
      );
    });

    test('a non-timeout failure keeps its cause and gains the context', () async {
      UniversalBle.setInstance(_WedgedPlatform(StateError('gatt boom')));
      final t = SramBleTransport('dev1', services);
      await expectLater(
        t.read(char),
        throwsA(
          isA<SramTransportException>()
              .having((e) => e.cause, 'cause', isA<StateError>())
              .having((e) => e.toString(), 'message', allOf(contains('gatt boom'), contains('(read $char)'))),
        ),
      );
    });
  });
}
