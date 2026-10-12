import 'dart:async';

import 'package:bike_control/bluetooth/devices/sram/sram_ble_transport.dart';
import 'package:bike_control/bluetooth/devices/sram/sram_link_errors.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/prop.dart' show SramBondException;

void main() {
  group('isSramLinkUnresponsive', () {
    test('a plain GATT timeout means the link is wedged', () {
      expect(isSramLinkUnresponsive(TimeoutException('Future not completed', const Duration(seconds: 10))), isTrue);
    });

    test('a handshake that timed out waiting for the derailleur means the link is wedged', () {
      final e = SramBondException(
        'handshake failed: TimeoutException after 0:00:15.000000: Future not completed\n#0 stack',
      );
      expect(isSramLinkUnresponsive(e), isTrue);
    });

    test('a create-bond decrypt failure is the authorize case, not a wedged link', () {
      final e = SramBondException(
        'create-bond decrypt failed — press and hold the AXS button to authorize this device, then retry.',
      );
      expect(isSramLinkUnresponsive(e), isFalse);
    });

    test('a handshake that failed for a non-timeout reason is not treated as wedged', () {
      expect(isSramLinkUnresponsive(SramBondException('handshake failed: PlatformException(x)')), isFalse);
    });

    test('a transport error wrapping a non-timeout cause is not treated as wedged', () {
      final e = SramTransportException('read', 'd905ee53-90aa-4c7c-b036-1e01fb8eb7ee', PlatformException(code: 'x'));
      expect(isSramLinkUnresponsive(e), isFalse);
    });

    test('an operation refused while the link is being reset counts as a link problem', () {
      expect(isSramLinkUnresponsive(const SramLinkResettingException()), isTrue);
    });

    test('unrelated errors are not link problems', () {
      expect(isSramLinkUnresponsive(StateError('SRAM: not bonded')), isFalse);
    });
  });
}
