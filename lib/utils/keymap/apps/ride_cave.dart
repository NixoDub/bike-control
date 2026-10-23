import 'package:bike_control/utils/keymap/apps/supported_app.dart';

import '../keymap.dart';

/// Ride Cave (https://ridecave.com) — officially supported via the open
/// OpenBikeControl protocol over Bluetooth. Ride Cave announces the buttons it
/// understands in its App Information message, so it needs no keyboard keymap.
class RideCave extends SupportedApp {
  @override
  List<(AppConnectionMethod, ConnectionSupport)> get connections => [
    (AppConnectionMethod.obpBle, ConnectionSupport.supported),
  ];

  @override
  String? get logoAsset => 'assets/ridecave.png';

  @override
  String? get officialUrl => 'https://ridecave.com';

  /// Ride Cave finds trainers over Bluetooth only.
  @override
  Set<TrainerConnectionType> get virtualShiftingTransports => const {
    TrainerConnectionType.bluetooth,
  };

  RideCave()
    : super(
        name: 'Ride Cave',
        packageName: 'Ride Cave',
        officialIntegration: true,
        keymap: Keymap(keyPairs: []),
      );
}
