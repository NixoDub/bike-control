import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:prop/emulators/transporter/dircon_codec.dart';
import 'package:prop/mdns/service_advertiser.dart';
import 'package:prop/transports/trainer_transport.dart';
import 'package:prop/utils/uuid.dart';
import 'package:universal_ble/universal_ble.dart';

/// A trainer that records what is done to it.
class FakeTrainerTransport extends TrainerTransport {
  final writes = <({String service, String characteristic, List<int> value, bool withoutResponse})>[];
  final subscriptions = <({String service, String characteristic, bool indicate})>[];
  final readValues = <String, Uint8List>{};
  final reads = <String>[];

  @override
  String get id => 'fake-trainer';

  @override
  Future<void> connect() async {}

  @override
  Future<List<BleService>> discoverServices() async => const [];

  @override
  Future<Uint8List> read(String service, String characteristic) async {
    reads.add(characteristic);
    return readValues[characteristic] ?? Uint8List(0);
  }

  @override
  Future<void> write(String service, String characteristic, Uint8List bytes, {bool withoutResponse = false}) async {
    writes.add((service: service, characteristic: characteristic, value: bytes, withoutResponse: withoutResponse));
  }

  @override
  Future<void> subscribe(String service, String characteristic, {required bool indicate}) async {
    subscriptions.add((service: service, characteristic: characteristic, indicate: indicate));
  }

  @override
  Stream<({String characteristic, Uint8List value})> get notifications => const Stream.empty();

  @override
  Future<void> disconnect() async {}
}

/// An advertiser that remembers what it was asked to announce.
class FakeAdvertiser implements ServiceAdvertiser {
  final registered = <AdvertisedService>[];
  int unregisterCalls = 0;

  @override
  ValueListenable<String?> get advertisedAddress => ServiceAdvertiser.untrackedAddress;

  @override
  Future<ServiceAdvertisement> register(AdvertisedService service) async {
    registered.add(service);
    return _FakeAdvertisement(this);
  }
}

class _FakeAdvertisement implements ServiceAdvertisement {
  _FakeAdvertisement(this._owner);
  final FakeAdvertiser _owner;

  @override
  Future<void> unregister() async => _owner.unregisterCalls++;
}

const ftmsService = '00001826-0000-1000-8000-00805f9b34fb';
const cyclingPowerService = '00001818-0000-1000-8000-00805f9b34fb';
const deviceInformationService = '0000180a-0000-1000-8000-00805f9b34fb';
const genericAccessService = '00001800-0000-1000-8000-00805f9b34fb';

const ftmsFeature = '00002acc-0000-1000-8000-00805f9b34fb';
const indoorBikeData = '00002ad2-0000-1000-8000-00805f9b34fb';
const controlPoint = '00002ad9-0000-1000-8000-00805f9b34fb';
const ftmsStatus = '00002ada-0000-1000-8000-00805f9b34fb';
const cyclingPowerMeasurement = '00002a63-0000-1000-8000-00805f9b34fb';
const manufacturerName = '00002a29-0000-1000-8000-00805f9b34fb';
const deviceName = '00002a00-0000-1000-8000-00805f9b34fb';

/// The services a smart trainer such as the JetBlack Victory exposes.
List<BleService> trainerServices() => [
  BleService(genericAccessService, [
    BleCharacteristic(deviceName, [CharacteristicProperty.read], []),
  ]),
  BleService(ftmsService, [
    BleCharacteristic(ftmsFeature, [CharacteristicProperty.read], []),
    BleCharacteristic(indoorBikeData, [CharacteristicProperty.notify], []),
    BleCharacteristic(controlPoint, [CharacteristicProperty.write, CharacteristicProperty.indicate], []),
    BleCharacteristic(ftmsStatus, [CharacteristicProperty.notify], []),
  ]),
  BleService(cyclingPowerService, [
    BleCharacteristic(cyclingPowerMeasurement, [CharacteristicProperty.notify], []),
  ]),
  BleService(deviceInformationService, [
    BleCharacteristic(manufacturerName, [CharacteristicProperty.read], []),
  ]),
];

/// A trainer app on the other end of the DirCon socket.
class DirconTestClient {
  DirconTestClient._(this.socket) {
    socket.listen((data) {
      for (final frame in _parser.add(data)) {
        if (frame.messageId == 6) {
          _notifications.add(frame);
        } else {
          _pending.remove(frame.sequence)?.complete(frame);
        }
      }
    }, onDone: () => closed.complete());
  }

  static Future<DirconTestClient> connect(int port) async =>
      DirconTestClient._(await Socket.connect(InternetAddress.loopbackIPv4, port));

  final Socket socket;
  final _parser = DirconFrameParser();
  final _pending = <int, Completer<DirconFrame>>{};
  final _notifications = StreamController<DirconFrame>.broadcast();
  final closed = Completer<void>();
  int _sequence = 0;

  Stream<DirconFrame> get notifications => _notifications.stream;

  Future<DirconFrame> request(int messageId, [List<int> payload = const []]) {
    final sequence = ++_sequence;
    final completer = _pending[sequence] = Completer<DirconFrame>();
    socket.add(encodeDirconFrame(messageId: messageId, sequence: sequence, responseCode: 0, payload: payload));
    return completer.future.timeout(const Duration(seconds: 5));
  }

  Future<List<String>> discoverServices() async {
    final response = await request(1);
    return [
      for (var i = 0; i + 16 <= response.payload.length; i += 16) uuidFromBytes(response.payload.sublist(i, i + 16)),
    ];
  }

  /// UUID -> property byte.
  Future<Map<String, int>> discoverCharacteristics(String service) async {
    final response = await request(2, uuidToBytes(service));
    final out = <String, int>{};
    for (var i = 16; i + 17 <= response.payload.length; i += 17) {
      out[uuidFromBytes(response.payload.sublist(i, i + 16))] = response.payload[i + 16];
    }
    return out;
  }

  Future<void> close() async {
    await socket.close();
    socket.destroy();
  }
}
