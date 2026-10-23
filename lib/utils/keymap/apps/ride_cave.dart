import 'package:bike_control/bluetooth/devices/openbikecontrol/protocol_parser.dart';
import 'package:bike_control/utils/keymap/apps/supported_app.dart';

import '../buttons.dart';
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

  /// The buttons Ride Cave lists in its App Information message, so riders can
  /// map them before Ride Cave first connects.
  @override
  List<ControllerButton> get defaultObpSupportedButtons => const [
    0x01, // Shift Up
    0x02, // Shift Down
    0x03, // Gear Set
    0x20, // Emote
    0x30, // Increase Difficulty
    0x31, // Decrease Difficulty
    0x32, // Skip Interval
    0x33, // Pause
    0x34, // Resume
  ].map((id) => OpenBikeProtocolParser.BUTTON_NAMES[id]!).toList();

  RideCave()
    : super(
        name: 'Ride Cave',
        packageName: 'Ride Cave',
        officialIntegration: true,
        keymap: Keymap(keyPairs: []),
      );
}
