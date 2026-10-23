import 'package:bike_control/utils/keymap/apps/supported_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SupportedApp rideCave() =>
      SupportedApp.supportedApps.firstWhere((app) => app.name == 'Ride Cave');

  test('Ride Cave is registered as an official supported app', () {
    final matches =
        SupportedApp.supportedApps.where((app) => app.name == 'Ride Cave');
    expect(matches, hasLength(1));
    expect(matches.first.officialIntegration, isTrue);
  });

  test('Ride Cave connects via the OpenBikeControl protocol over Bluetooth', () {
    final app = rideCave();
    expect(app.supportLevel(AppConnectionMethod.obpBle),
        ConnectionSupport.supported);
    expect(app.supportLevel(AppConnectionMethod.obpMdns), isNull);
    // OBC delivers button events over the protocol, so there is no keyboard map.
    expect(app.keymap.keyPairs, isEmpty);
  });

  test('Ride Cave finds trainers over Bluetooth only', () {
    expect(rideCave().virtualShiftingTransports,
        {TrainerConnectionType.bluetooth});
  });

  test('Ride Cave lists the buttons it supports before it first connects', () {
    expect(
      rideCave().defaultObpSupportedButtons.map((b) => b.identifier).toList(),
      [0x01, 0x02, 0x03, 0x20, 0x30, 0x31, 0x32, 0x33, 0x34],
    );
  });

  test('Ride Cave ships a logo asset and links to ridecave.com', () {
    expect(rideCave().logoAsset, 'assets/ridecave.png');
    expect(rideCave().officialUrl, 'https://ridecave.com');
  });
}
