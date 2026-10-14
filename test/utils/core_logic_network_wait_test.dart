import 'dart:io';

import 'package:bike_control/utils/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/utils/network_address.dart';

/// A network method that fails to start before the machine has an address
/// (BikeControl autostarting ahead of Wi-Fi) must wait for the network instead
/// of being switched off.
void main() {
  final original = AdvertisedAddressPicker.listInterfaces;
  tearDown(() => AdvertisedAddressPicker.listInterfaces = original);

  test('no usable address yet: the failure is "offline" and the method stays enabled', () async {
    AdvertisedAddressPicker.listInterfaces = () async => [];
    expect(await CoreLogic().waitForNetworkIfOffline(), isTrue);
  });

  test('an address is available: the failure is real and handled as before', () async {
    final interfaces = await NetworkInterface.list();
    final hasIpv4 = interfaces.any((i) => i.addresses.any((a) => a.type == InternetAddressType.IPv4 && !a.isLoopback));
    if (!hasIpv4) return markTestSkipped('this test host has no IPv4 interface');
    expect(await CoreLogic().waitForNetworkIfOffline(), isFalse);
  });
}
