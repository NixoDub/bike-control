import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nsd_platform_interface/nsd_platform_interface.dart';
import 'package:prop/mdns/service_advertiser.dart';

/// Stands in for the system's service announcer.
class _FakeNsd extends NsdPlatformInterface {
  _FakeNsd() : super();

  final registered = <Service>[];
  final unregistered = <Registration>[];
  bool failUnregister = false;

  @override
  Future<Registration> register(Service service) async {
    registered.add(service);
    return Registration('r${registered.length}', service);
  }

  @override
  Future<void> unregister(Registration registration) async {
    if (failUnregister) throw StateError('network gone');
    unregistered.add(registration);
  }

  @override
  Future<Discovery> startDiscovery(String serviceType, {bool autoResolve = true, IpLookupType ipLookupType = IpLookupType.none}) =>
      throw UnimplementedError();

  @override
  Future<void> stopDiscovery(Discovery discovery) => throw UnimplementedError();

  @override
  Future<Service> resolve(Service service) => throw UnimplementedError();

  @override
  Future<void> disableServiceTypeValidation(bool disable) async {}

  @override
  Future<void> enableLogging(LogTopic logTopic) async {}
}

void main() {
  late _FakeNsd fake;
  setUp(() {
    fake = _FakeNsd();
    NsdPlatformInterface.instance = fake;
  });

  AdvertisedService service() => AdvertisedService(
    name: 'Victory DF20 - BikeControl',
    type: '_wahoo-fitness-tnp._tcp',
    port: 36868,
    address: InternetAddress('192.168.1.50'),
    txt: {'mac-address': Uint8List.fromList('02:BC:0C:00:00:01'.codeUnits), 'ble-service-uuids': Uint8List.fromList('0x1826'.codeUnits)},
  );

  test('registers the service with its name, type, port and TXT record', () async {
    await NsdServiceAdvertiser().register(service());
    final sent = fake.registered.single;
    expect(sent.name, 'Victory DF20 - BikeControl');
    expect(sent.type, '_wahoo-fitness-tnp._tcp');
    expect(sent.port, 36868);
    expect(String.fromCharCodes(sent.txt!['mac-address']!), '02:BC:0C:00:00:01');
    expect(String.fromCharCodes(sent.txt!['ble-service-uuids']!), '0x1826');
  });

  test('unregisters once, and a system that already forgot it is not an error', () async {
    final advertisement = await NsdServiceAdvertiser().register(service());
    await advertisement.unregister();
    await advertisement.unregister();
    expect(fake.unregistered, hasLength(1));

    fake.failUnregister = true;
    final other = await NsdServiceAdvertiser().register(service());
    await other.unregister();
  });

  test('a desktop keeps the in-process responder as its default', () {
    expect(ServiceAdvertiser.platformDefault(), isA<ResponderServiceAdvertiser>());
  });
}
