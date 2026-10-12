import 'dart:async';

import 'package:prop/prop.dart' show SramBondException;

/// Thrown when setup/restore is attempted while `SramAxs` is still
/// re-establishing a link it tore down because the derailleur stopped
/// answering. Retrying once the device shows as connected again works.
class SramLinkResettingException implements Exception {
  const SramLinkResettingException();

  @override
  String toString() => 'SramLinkResettingException: reconnecting to the derailleur, retry once it is connected';
}

/// Whether [error] means the BLE link to the derailleur stopped answering —
/// as opposed to the derailleur answering with a refusal.
///
/// - a GATT read/write/subscribe that never completed (universal_ble's
///   queue raises a [TimeoutException], see `SramBleTransport`);
/// - a bond handshake that timed out waiting for the derailleur's reply
///   (prop wraps it as `SramBondException('handshake failed: TimeoutException…')`);
/// - an attempt refused because such a link is still being reset.
///
/// A `create-bond decrypt failed` bond error is NOT a link problem: the
/// derailleur replied, it just wasn't authorized (AXS button not held).
bool isSramLinkUnresponsive(Object error) {
  if (error is TimeoutException || error is SramLinkResettingException) return true;
  if (error is SramBondException) {
    final message = error.message;
    return message.startsWith('handshake failed:') && message.contains('TimeoutException');
  }
  return false;
}
