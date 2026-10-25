// The whole proxy path on loopback: a stand-in trainer app speaks DirCon over
// TCP to a real DirconEmulator, which relays to a fake trainer. Covers what
// the app needs from `prop` in proxy mode: discovery, reads, writes,
// notifications both ways, the mDNS announcement and the lifecycle.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/definitions/proxy_bike_definition.dart';
import 'package:prop/emulators/dircon_emulator.dart';
import 'package:prop/emulators/transporter/dircon_codec.dart';
import 'package:prop/mdns/service_advertiser.dart';
import 'package:prop/utils/network_address.dart';
import 'package:prop/utils/shared.dart';
import 'package:prop/utils/uuid.dart';
import 'package:universal_ble/universal_ble.dart';

import 'helpers.dart';

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late FakeTrainerTransport trainer;
  late FakeAdvertiser advertiser;
  late DirconEmulator emulator;
  late ProxyBikeDefinition definition;
  late ServiceAdvertiser previousAdvertiser;
  DirconTestClient? client;

  setUp(() async {
    previousAdvertiser = ServiceAdvertiser.instance;
    advertiser = FakeAdvertiser();
    ServiceAdvertiser.instance = advertiser;
    AdvertisedAddressPicker.debugPick = () async => InternetAddress('192.168.1.50');

    trainer = FakeTrainerTransport();
    emulator = DirconEmulator(preferredPort: 0)..deviceName = () => 'JetBlack Victory';
    definition = ProxyBikeDefinition(
      services: trainerServices(),
      device: BleDevice(deviceId: 'AA:BB:CC:DD:EE:FF', name: 'JetBlack Victory'),
      data: emulator.data,
      transport: trainer,
    );
  });

  tearDown(() async {
    await client?.close();
    client = null;
    await emulator.stop();
    ServiceAdvertiser.instance = previousAdvertiser;
    AdvertisedAddressPicker.debugPick = null;
  });

  Future<void> start({Map<String, Uint8List> txt = const {}}) async {
    await emulator.attachDefinition(definition);
    await emulator.startServer(mode: RetrofitMode.proxy, mdnsTxt: txt);
    client = await DirconTestClient.connect(emulator.boundPort!);
    await settle();
  }

  group('discovery', () {
    test('serves the trainer\'s services, without Generic Access', () async {
      await start();
      expect(await client!.discoverServices(), [ftmsService, cyclingPowerService, deviceInformationService]);
    });

    test('describes each characteristic with its read / write / notify bits', () async {
      await start();
      expect(await client!.discoverCharacteristics(ftmsService), {
        ftmsFeature: 0x01,
        indoorBikeData: 0x04,
        controlPoint: 0x06,
        ftmsStatus: 0x04,
      });
    });

    test('says so for an unknown service', () async {
      await start();
      final response = await client!.request(2, uuidToBytes('0000dead-0000-1000-8000-00805f9b34fb'));
      expect(response.responseCode, 3);
    });

    test('answers a request split across TCP segments', () async {
      await start();
      final request = encodeDirconFrame(messageId: 1, sequence: 7, responseCode: 0);
      final reply = Completer<DirconFrame>();
      final parser = DirconFrameParser();
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, emulator.boundPort!);
      socket.listen((d) => parser.add(d).forEach(reply.complete));
      socket.add(request.sublist(0, 3));
      await settle();
      socket.add(request.sublist(3));
      final frame = await reply.future.timeout(const Duration(seconds: 5));
      expect(frame.sequence, 7);
      expect(frame.payload.length, 48);
      socket.destroy();
    });

    test('refuses an unknown protocol version and an unknown message', () async {
      await start();
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, emulator.boundPort!);
      final frames = <DirconFrame>[];
      final parser = DirconFrameParser();
      socket.listen((d) => frames.addAll(parser.add(d)));
      socket.add(encodeDirconFrame(messageId: 1, sequence: 1, responseCode: 0, version: 9));
      socket.add(encodeDirconFrame(messageId: 42, sequence: 2, responseCode: 0));
      await settle();
      expect(frames.map((f) => f.responseCode), [7, 1]);
      socket.destroy();
    });
  });

  group('what the app log shows of a client', () {
    test('its connection, what it asks for and what the bridge refuses', () async {
      final events = <String>[];
      Logger.onEvent = events.add;
      addTearDown(() => Logger.onEvent = null);
      await start();
      await client!.discoverServices();
      await client!.request(3, uuidToBytes(indoorBikeData));
      await client!.request(2, uuidToBytes('0000dead-0000-1000-8000-00805f9b34fb'));
      await settle();
      expect(events, contains(startsWith('DirCon: client connected from')));
      expect(events, contains('DirCon client: discover services'));
      expect(events.any((e) => e.startsWith('DirCon client: read 2ad2')), isTrue);
      expect(events.any((e) => e.startsWith('DirCon: refused message 2 with code 3')), isTrue);
    });
  });

  group('relaying to the trainer', () {
    test('reads go to the trainer', () async {
      trainer.readValues[manufacturerName] = Uint8List.fromList('JetBlack'.codeUnits);
      await start();
      final response = await client!.request(3, uuidToBytes(manufacturerName));
      expect(response.responseCode, 0);
      expect(uuidFromBytes(response.payload.sublist(0, 16)), manufacturerName);
      expect(String.fromCharCodes(response.payload.sublist(16)), 'JetBlack');
    });

    test('a control point write reaches the trainer, with the service it belongs to', () async {
      await start();
      final response = await client!.request(4, [...uuidToBytes(controlPoint), 0x00]);
      expect(response.responseCode, 0);
      await settle();
      expect(trainer.writes, hasLength(1));
      expect(trainer.writes.single.service, ftmsService);
      expect(trainer.writes.single.characteristic, controlPoint);
      expect(trainer.writes.single.value, [0x00]);
      expect(trainer.writes.single.withoutResponse, isFalse);
    });

    test('writes arrive in the order they were sent', () async {
      await start();
      for (final opcode in [0x00, 0x07, 0x05]) {
        await client!.request(4, [...uuidToBytes(controlPoint), opcode]);
      }
      await settle();
      expect(trainer.writes.map((w) => w.value.first), [0x00, 0x07, 0x05]);
    });

    test('a write that is too short, or to an unknown characteristic, is refused', () async {
      await start();
      expect((await client!.request(4, [1, 2, 3])).responseCode, 6);
      expect((await client!.request(4, uuidToBytes('0000beef-0000-1000-8000-00805f9b34fb'))).responseCode, 4);
      expect(trainer.writes, isEmpty);
    });

    test('enabling notifications subscribes upstream once, as an indication where the trainer indicates', () async {
      await start();
      await client!.request(5, [...uuidToBytes(controlPoint), 1]);
      await client!.request(5, [...uuidToBytes(controlPoint), 1]);
      await settle();
      final subscriptions = trainer.subscriptions.where((s) => s.characteristic == controlPoint).toList();
      expect(subscriptions, hasLength(1));
      expect(subscriptions.single.indicate, isTrue);
    });

    test('the metric characteristics are followed as soon as the relay is up', () async {
      await start();
      expect(
        trainer.subscriptions.map((s) => s.characteristic),
        containsAll([indoorBikeData, cyclingPowerMeasurement]),
      );
    });
  });

  group('notifications from the trainer', () {
    final bike = Uint8List.fromList([0x44, 0x00, 0xB8, 0x0B, 0xB4, 0x00, 0xFA, 0x00]);

    test('reach a client that enabled them, in a DirCon notification frame', () async {
      await start();
      await client!.request(5, [...uuidToBytes(indoorBikeData), 1]);
      final received = client!.notifications.first;
      expect(emulator.processCharacteristic(indoorBikeData, bike), isTrue);
      final frame = await received.timeout(const Duration(seconds: 5));
      expect(frame.messageId, 6);
      expect(uuidFromBytes(frame.payload.sublist(0, 16)), indoorBikeData);
      expect(frame.payload.sublist(16), bike);
    });

    test('are not sent for something the client did not ask for', () async {
      await start();
      var heard = 0;
      client!.notifications.listen((_) => heard++);
      emulator.processCharacteristic(indoorBikeData, bike);
      await settle();
      expect(heard, 0);
    });

    test('are matched whatever the case or form of the UUID', () async {
      await start();
      await client!.request(5, [...uuidToBytes(indoorBikeData), 1]);
      final received = client!.notifications.first;
      emulator.processCharacteristic('2AD2', bike);
      await received.timeout(const Duration(seconds: 5));
    });

    test('a characteristic nobody carries is reported as not handled', () async {
      await start();
      expect(emulator.processCharacteristic('00002a99-0000-1000-8000-00805f9b34fb', Uint8List(1)), isFalse);
    });

    test('feed the app\'s own readout of power, cadence and speed', () async {
      await start();
      emulator.processCharacteristic(indoorBikeData, bike);
      expect(definition.powerW.value, 250);
      expect(definition.cadenceRpm.value, 90);
      expect(definition.speedKph.value, closeTo(30.0, 0.001));
      expect(emulator.data.value, contains('250 W'));
    });
  });

  group('announcing over mDNS', () {
    test('registers a Wahoo DirCon service with the trainer\'s name and the real port', () async {
      await start(txt: {'serial-number': Uint8List.fromList('123456789'.codeUnits)});
      final service = advertiser.registered.single;
      expect(service.type, '_wahoo-fitness-tnp._tcp');
      expect(service.name, 'JetBlack Victory - BikeControl');
      expect(service.port, emulator.boundPort);
      expect(service.address.address, '192.168.1.50');
      expect(String.fromCharCodes(service.txt['serial-number']!), '123456789');
    });

    test('advertises the cycling profiles as 0x-prefixed 16-bit UUIDs', () async {
      await start();
      final txt = String.fromCharCodes(advertiser.registered.single.txt['ble-service-uuids']!);
      expect(txt, '0x1826,0x1818');
    });

    test('advertises them bare when the trainer app wants that', () async {
      emulator.bareShortServiceUuids = () => true;
      await start();
      expect(String.fromCharCodes(advertiser.registered.single.txt['ble-service-uuids']!), '1826,1818');
    });

    test('keeps the name the app chose', () async {
      emulator.advertisementNameOverride = () => 'Bridge';
      await start();
      expect(advertiser.registered.single.name, 'Bridge');
    });

    test('stays silent while it should not advertise, but still serves', () async {
      emulator.shouldAdvertise = () => false;
      await start();
      expect(advertiser.registered, isEmpty);
      expect(await client!.discoverServices(), isNotEmpty);
    });

    test('pausing withdraws the announcement and leaves the connection alone', () async {
      await start();
      await emulator.pauseAdvertising();
      expect(advertiser.unregisterCalls, 1);
      expect(emulator.isStarted.value, isTrue);
      expect(emulator.isConnected.value, isTrue);
      expect(await client!.discoverServices(), isNotEmpty);
    });

    test('nothing is announced when there is nothing to serve', () async {
      await emulator.startServer(mode: RetrofitMode.proxy);
      expect(advertiser.registered, isEmpty);
      expect(emulator.isStarted.value, isTrue);
    });

    test('attaching while running announces the new set of services', () async {
      await emulator.startServer(mode: RetrofitMode.proxy);
      await emulator.attachDefinition(definition);
      expect(advertiser.registered, hasLength(1));
    });
  });

  group('lifecycle', () {
    test('reports started, connected and the address', () async {
      expect(emulator.isStarted.value, isFalse);
      await start();
      expect(emulator.isStarted.value, isTrue);
      expect(emulator.isConnected.value, isTrue);
      expect(emulator.localAddress.value, '192.168.1.50');
    });

    test('notices the client leaving', () async {
      await start();
      await client!.close();
      await client!.closed.future.timeout(const Duration(seconds: 5));
      await settle();
      expect(emulator.isConnected.value, isFalse);
      expect(emulator.isStarted.value, isTrue);
    });

    test('a new client replaces the old one', () async {
      await start();
      final second = await DirconTestClient.connect(emulator.boundPort!);
      await settle();
      expect(await second.discoverServices(), isNotEmpty);
      await client!.closed.future.timeout(const Duration(seconds: 5));
      expect(emulator.isConnected.value, isTrue);
      await second.close();
    });

    test('stopping withdraws the announcement and closes the port', () async {
      await start();
      final port = emulator.boundPort!;
      await emulator.stop();
      expect(emulator.isStarted.value, isFalse);
      expect(emulator.isConnected.value, isFalse);
      expect(emulator.boundPort, isNull);
      expect(advertiser.unregisterCalls, 1);
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port), throwsA(isA<SocketException>()));
    });

    test('restarting announces again', () async {
      await start();
      await emulator.restart();
      expect(advertiser.registered, hasLength(2));
      expect(emulator.isStarted.value, isTrue);
    });

    test('refuses a Bluetooth bridge, which this build cannot serve', () async {
      await expectLater(emulator.startServer(mode: RetrofitMode.bluetooth), throwsA(isA<UnsupportedError>()));
      expect(emulator.isStarted.value, isFalse);
    });

    test('fails honestly when the host has no network address', () async {
      AdvertisedAddressPicker.debugPick = () async => null;
      await expectLater(emulator.startServer(mode: RetrofitMode.proxy), throwsA(isA<String>()));
      expect(emulator.isStarted.value, isFalse);
    });

    test('prefers the Wahoo standard port exactly while asked to', () {
      var standard = false;
      final e = DirconEmulator(preferredPort: 40000)..preferStandardPort = () => standard;
      expect(e.preferredPort, 40000);
      standard = true;
      expect(e.preferredPort, kWahooDirconStandardPort);
    });

    test('binds the port it was given when that port is free', () async {
      final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final free = probe.port;
      await probe.close();
      final standard = DirconEmulator(preferredPort: free)..preferStandardPort = () => false;
      await standard.attachDefinition(
        ProxyBikeDefinition(
          services: trainerServices(),
          device: BleDevice(deviceId: 'x', name: 'x'),
          data: standard.data,
          transport: trainer,
        ),
      );
      await standard.startServer(mode: RetrofitMode.proxy);
      expect(standard.boundPort, free);
      await standard.stop();
    });
  });

  group('measurement parsing', () {
    test('heart rate, 8 and 16 bit', () {
      expect(ProxyBikeDefinition.parseHeartRate(Uint8List.fromList([0x00, 72])), 72);
      expect(ProxyBikeDefinition.parseHeartRate(Uint8List.fromList([0x01, 0x2C, 0x01])), 300);
      expect(ProxyBikeDefinition.parseHeartRate(Uint8List.fromList([0x00])), isNull);
    });

    test('cycling power is signed', () {
      expect(ProxyBikeDefinition.parseCyclingPower(Uint8List.fromList([0, 0, 0xFA, 0x00])), 250);
      expect(ProxyBikeDefinition.parseCyclingPower(Uint8List.fromList([0, 0, 0xFF, 0xFF])), -1);
      expect(ProxyBikeDefinition.parseCyclingPower(Uint8List.fromList([0, 0])), isNull);
    });

    test('indoor bike data skips the fields that precede the ones it reads', () {
      // speed, average speed, cadence, average cadence, distance, resistance, power, average power, energy, HR
      final bytes = Uint8List.fromList([
        0xFE, 0x03, // flags: everything but "more data" (bit 0 clear) up to heart rate
        0x10, 0x27, // speed 100.00
        0x00, 0x00, // average speed
        0x50, 0x00, // cadence 40 rpm
        0x00, 0x00, // average cadence
        0x00, 0x00, 0x00, // total distance
        0x05, 0x00, // resistance level
        0x2C, 0x01, // power 300
        0x00, 0x00, // average power
        0x00, 0x00, 0x00, 0x00, 0x00, // expended energy
        0x99, // heart rate 153
      ]);
      final parsed = ProxyBikeDefinition.parseIndoorBikeData(bytes);
      expect(parsed.speedKph, 100.0);
      expect(parsed.cadenceRpm, 40);
      expect(parsed.powerW, 300);
      expect(parsed.heartRateBpm, 153);
    });

    test('indoor bike data survives a truncated frame', () {
      final parsed = ProxyBikeDefinition.parseIndoorBikeData(Uint8List.fromList([0x44, 0x00, 0xB8]));
      expect(parsed.speedKph, isNull);
      expect(parsed.powerW, isNull);
    });
  });
}
