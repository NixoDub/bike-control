import 'dart:async';

import 'package:bike_control/bluetooth/ble_command_queue_config.dart';
import 'package:bike_control/bluetooth/emulation/emulated_ble_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

/// Writes park until the test releases them, so the test can observe which
/// commands universal_ble lets run concurrently.
class _GatedWritePlatform extends FakeUniversalBlePlatform {
  final started = <String>[];
  final gates = <String, Completer<void>>{};

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) {
    final tag = '$deviceId#${value.first}';
    started.add(tag);
    return (gates[tag] = Completer<void>()).future;
  }
}

void main() {
  const service = '0000180f-0000-1000-8000-00805f9b34fb';
  const characteristic = '00002a19-0000-1000-8000-00805f9b34fb';

  late _GatedWritePlatform ble;

  setUp(() {
    ble = _GatedWritePlatform();
    UniversalBle.setInstance(ble);
    configureBleCommandQueues();
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<void> write(String deviceId, int marker) =>
      UniversalBle.write(deviceId, service, characteristic, Uint8List.fromList([marker]));

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.windows]) {
    group(platform.name, () {
      setUp(() => debugDefaultTargetPlatformOverride = platform);

      test('commands to ONE device stay serialized, as they were with the 2.x global queue', () async {
        final first = write('aa:aa:aa:aa:aa:aa', 1);
        final second = write('aa:aa:aa:aa:aa:aa', 2);
        await pumpEventQueue();

        expect(ble.started, ['aa:aa:aa:aa:aa:aa#1']);

        ble.gates['aa:aa:aa:aa:aa:aa#1']!.complete();
        await first;
        await pumpEventQueue();
        expect(ble.started, ['aa:aa:aa:aa:aa:aa#1', 'aa:aa:aa:aa:aa:aa#2']);

        ble.gates['aa:aa:aa:aa:aa:aa#2']!.complete();
        await second;
      });

      test('a slow command on one device does not hold up another device', () async {
        final trainerWrite = write('aa:aa:aa:aa:aa:aa', 1);
        final controllerWrite = write('bb:bb:bb:bb:bb:bb', 1);
        await pumpEventQueue();

        expect(ble.started, containsAll(['aa:aa:aa:aa:aa:aa#1', 'bb:bb:bb:bb:bb:bb#1']));

        ble.gates['bb:bb:bb:bb:bb:bb#1']!.complete();
        await controllerWrite;
        ble.gates['aa:aa:aa:aa:aa:aa#1']!.complete();
        await trainerWrite;
      });
    });
  }
}
