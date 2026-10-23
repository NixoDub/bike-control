import 'package:bike_control/bluetooth/devices/openbikecontrol/protocol_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final emote = OpenBikeProtocolParser.BUTTON_NAMES[0x20]!;
  final shiftUp = OpenBikeProtocolParser.BUTTON_NAMES[0x01]!;

  test('an Emote with a chosen value sends it as value + 1', () {
    expect(OpenBikeProtocolParser.pressedState(emote, 1), 0x02);
    expect(OpenBikeProtocolParser.pressedState(emote, 6), 0x07);
  });

  test('an Emote without a value is a plain press', () {
    expect(OpenBikeProtocolParser.pressedState(emote, null), 0x01);
  });

  test('a value outside the app-specific emote range is a plain press', () {
    expect(OpenBikeProtocolParser.pressedState(emote, 0), 0x01);
    expect(OpenBikeProtocolParser.pressedState(emote, 0x1F), 0x01);
  });

  test('other buttons ignore a value', () {
    expect(OpenBikeProtocolParser.pressedState(shiftUp, 3), 0x01);
  });

  test('the value reaches the encoded button state', () {
    final bytes = OpenBikeProtocolParser.encodeButtonState([
      ButtonState(emote, OpenBikeProtocolParser.pressedState(emote, 3)),
    ]);
    expect(bytes, [0x01, 0x20, 0x04]);
  });
}
