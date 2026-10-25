import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prop/dircon/dircon_trainer_transport.dart';
import 'package:prop/emulators/transporter/dircon_codec.dart';
import 'package:prop/utils/uuid.dart';
import 'package:universal_ble/universal_ble.dart';

/// A trainer on the other end of the socket: one service (FTMS) with a
/// readable, a writable and a notifying characteristic.
class _FakeDirconTrainer {
  _FakeDirconTrainer._(this.server) {
    server.listen((socket) {
      client = socket;
      final parser = DirconFrameParser();
      socket.listen((data) {
        for (final frame in parser.add(data)) {
          _answer(socket, frame);
        }
      });
    });
  }

  static Future<_FakeDirconTrainer> start() async =>
      _FakeDirconTrainer._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket server;
  Socket? client;
  final writes = <(String, List<int>)>[];
  final enabled = <String>[];

  static const service = '00001826-0000-1000-8000-00805f9b34fb';
  static const feature = '00002acc-0000-1000-8000-00805f9b34fb';
  static const control = '00002ad9-0000-1000-8000-00805f9b34fb';
  static const bikeData = '00002ad2-0000-1000-8000-00805f9b34fb';

  void _reply(Socket s, DirconFrame f, List<int> payload, {int rc = 0}) =>
      s.add(encodeDirconFrame(messageId: f.messageId, sequence: f.sequence, responseCode: rc, payload: payload));

  void _answer(Socket s, DirconFrame f) {
    switch (f.messageId) {
      case 1:
        _reply(s, f, uuidToBytes(service));
      case 2:
        _reply(s, f, [
          ...uuidToBytes(service),
          ...uuidToBytes(feature), 1,
          ...uuidToBytes(control), 2 | 4,
          ...uuidToBytes(bikeData), 4,
        ]);
      case 3:
        _reply(s, f, [...f.payload.sublist(0, 16), 0x86, 0x14, 0, 0, 0, 0, 0, 0]);
      case 4:
        writes.add((uuidFromBytes(f.payload.sublist(0, 16)), f.payload.sublist(16).toList()));
        _reply(s, f, f.payload.sublist(0, 16));
      case 5:
        enabled.add(uuidFromBytes(f.payload.sublist(0, 16)));
        _reply(s, f, f.payload.sublist(0, 16));
      default:
        _reply(s, f, const [], rc: 1);
    }
  }

  void notify(String characteristic, List<int> value) => client!.add(
    encodeDirconFrame(messageId: 6, sequence: 0, responseCode: 0, payload: [...uuidToBytes(characteristic), ...value]),
  );

  Future<void> close() async {
    client?.destroy();
    await server.close();
  }
}

void main() {
  late _FakeDirconTrainer trainer;
  late DirconTrainerTransport transport;

  setUp(() async {
    trainer = await _FakeDirconTrainer.start();
    transport = DirconTrainerTransport(id: 'wifi-1', host: '127.0.0.1', port: trainer.server.port);
    await transport.connect();
  });

  tearDown(() async {
    await transport.disconnect();
    await trainer.close();
  });

  test('discovers services with their characteristics and properties', () async {
    final services = await transport.discoverServices();
    expect(services.map((s) => s.uuid), [_FakeDirconTrainer.service]);
    final byUuid = {for (final c in services.single.characteristics) c.uuid: c.properties};
    expect(byUuid[_FakeDirconTrainer.feature], [CharacteristicProperty.read]);
    expect(byUuid[_FakeDirconTrainer.control], [CharacteristicProperty.write, CharacteristicProperty.notify]);
    expect(byUuid[_FakeDirconTrainer.bikeData], [CharacteristicProperty.notify]);
  });

  test('reads a characteristic without the uuid echo', () async {
    final value = await transport.read(_FakeDirconTrainer.service, _FakeDirconTrainer.feature);
    expect(value, [0x86, 0x14, 0, 0, 0, 0, 0, 0]);
  });

  test('writes and subscribes by characteristic', () async {
    await transport.write(_FakeDirconTrainer.service, _FakeDirconTrainer.control, Uint8List.fromList([0x00]));
    await transport.subscribe(_FakeDirconTrainer.service, _FakeDirconTrainer.bikeData, indicate: false);
    expect(trainer.writes.map((w) => w.$1), [_FakeDirconTrainer.control]);
    expect(trainer.writes.single.$2, [0x00]);
    expect(trainer.enabled, [_FakeDirconTrainer.bikeData]);
  });

  test('delivers notifications from the trainer', () async {
    final first = transport.notifications.first;
    await transport.subscribe(_FakeDirconTrainer.service, _FakeDirconTrainer.bikeData, indicate: false);
    trainer.notify(_FakeDirconTrainer.bikeData, [1, 2, 3]);
    final n = await first.timeout(const Duration(seconds: 2));
    expect(n.characteristic, _FakeDirconTrainer.bikeData);
    expect(n.value, [1, 2, 3]);
  });

  test('a trainer that hangs up is reported, a deliberate disconnect is not', () async {
    var drops = 0;
    transport.onDisconnected = () => drops++;
    await transport.read(_FakeDirconTrainer.service, _FakeDirconTrainer.feature);
    trainer.client!.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(drops, 1);
    expect(transport.isConnected, isFalse);

    final again = DirconTrainerTransport(id: 'x', host: '127.0.0.1', port: trainer.server.port);
    var dropsAgain = 0;
    again.onDisconnected = () => dropsAgain++;
    await again.connect();
    await again.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(dropsAgain, 0);
  });

  test('a request on a closed connection fails instead of hanging', () async {
    await transport.disconnect();
    expect(transport.read(_FakeDirconTrainer.service, _FakeDirconTrainer.feature), throwsA(isA<SocketException>()));
  });
}
