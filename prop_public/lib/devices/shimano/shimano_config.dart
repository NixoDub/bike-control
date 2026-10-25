//INFO: This is a stub - contact me if you need the full implementation.
//
// The full implementation authenticates against the Di2 config service and
// decodes its button-mode paddle telemetry. All bodies here are stubbed and
// every UUID / passkey below is a FAKE placeholder.

import 'dart:async';
import 'dart:typed_data';

/// BLE seam for the Shimano protocol code. The app supplies a `universal_ble`
/// backed implementation; tests supply a fake.
abstract class ShimanoTransport {
  Future<void> subscribe(String characteristic);
  Future<void> write(String characteristic, Uint8List data, {bool withoutResponse = false});
  Future<Uint8List> read(String characteristic);

  /// Notifications delivered on [characteristic] after [subscribe].
  Stream<Uint8List> notifications(String characteristic);
}

/// Characteristics of the Di2 config service. FAKE placeholder UUIDs.
class ShimanoDi2Config {
  ShimanoDi2Config._();

  static const String authControlChar = '00000000-0000-0000-0000-0000000000e0';
  static const String pceResponseChar = '00000000-0000-0000-0000-0000000000e1';
  static const String pceAuxNotify1 = '00000000-0000-0000-0000-0000000000e2';
  static const String pceAuxNotify2 = '00000000-0000-0000-0000-0000000000e3';
}

class ShimanoAuth {
  ShimanoAuth._();

  /// FAKE placeholder: the real default passkey lives in the full package.
  static const String defaultPasskey = '00000000';
}

/// The Di2 refused the passkey.
class ShimanoPasskeyRejectedException implements Exception {
  ShimanoPasskeyRejectedException([this.message = 'passkey rejected']);
  final String message;
  @override
  String toString() => 'ShimanoPasskeyRejectedException: $message';
}

/// The authentication handshake failed for another reason.
class ShimanoAuthException implements Exception {
  ShimanoAuthException(this.message);
  final String message;
  @override
  String toString() => 'ShimanoAuthException: $message';
}

enum ShimanoShifter { left, right }

enum ShimanoPaddle { big, small, hood, satellite }

enum ShimanoPaddleState { down, released, held }

class ShimanoPaddleEvent {
  const ShimanoPaddleEvent(this.shifter, this.paddle, this.state);
  final ShimanoShifter shifter;
  final ShimanoPaddle paddle;
  final ShimanoPaddleState state;
}

/// A running button-mode session; closing it lets the Di2 shift by itself.
class ShimanoButtonSession {
  const ShimanoButtonSession();

  Future<void> close() async {}
}

class ShimanoConfig {
  ShimanoConfig._();

  /// Stubbed: the full implementation runs the Di2 authentication handshake.
  static Future<void> authenticate(ShimanoTransport transport, {required String passkey}) =>
      throw UnimplementedError();

  /// Stubbed: the full implementation replays the button-mode sequence and
  /// reports paddle presses through [onPaddle].
  static Future<ShimanoButtonSession> enterButtonMode(
    ShimanoTransport transport, {
    required void Function(ShimanoPaddleEvent event) onPaddle,
    required void Function(Uint8List frame) onUnknownFrame,
    required void Function(String step, Object error, StackTrace stackTrace) onStepError,
  }) => throw UnimplementedError();
}
