import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/transporter/dircon_codec.dart';
import 'package:prop/utils/uuid.dart';

void main() {
  group('UUIDs', () {
    test('expand every spelling of a short UUID to the same full form', () {
      const full = '00001826-0000-1000-8000-00805f9b34fb';
      for (final spelling in ['1826', '0x1826', '0X1826', '00001826', full, full.toUpperCase(), '  1826 ']) {
        expect(normalizeUuid(spelling), full, reason: spelling);
      }
      expect(normalizeUuid('000018260000100080 0000805f9b34fb'.replaceAll(' ', '')), full);
    });

    test('leave a custom 128-bit UUID alone, but lower-cased', () {
      expect(
        normalizeUuid('A026EE01-0A7D-4AB3-97FA-F1500F9FEB8B'),
        'a026ee01-0a7d-4ab3-97fa-f1500f9feb8b',
      );
    });

    test('round-trip through the 16-byte wire form', () {
      const uuid = 'a026ee01-0a7d-4ab3-97fa-f1500f9feb8b';
      final bytes = uuidToBytes(uuid);
      expect(bytes.length, 16);
      expect(bytes.first, 0xa0);
      expect(bytes.last, 0x8b);
      expect(uuidFromBytes(bytes), uuid);
      expect(uuidToBytes('1826').sublist(0, 4), [0x00, 0x00, 0x18, 0x26]);
    });

    test('refuse what is not a UUID', () {
      expect(() => uuidToBytes('nonsense'), throwsFormatException);
      expect(() => uuidFromBytes([1, 2, 3]), throwsArgumentError);
    });

    test('short form exists only on the SIG base', () {
      expect(shortUuidOf('00001826-0000-1000-8000-00805f9b34fb'), '1826');
      expect(shortUuidOf('0x180D'), '180d');
      expect(shortUuidOf('a026ee01-0a7d-4ab3-97fa-f1500f9feb8b'), isNull);
    });
  });

  group('DirCon frames', () {
    test('write the 6-byte header and the payload', () {
      final bytes = encodeDirconFrame(messageId: 4, sequence: 9, responseCode: 0, payload: [1, 2, 3]);
      expect(bytes, [1, 4, 9, 0, 0, 3, 1, 2, 3]);
    });

    test('write the length big-endian', () {
      final bytes = encodeDirconFrame(messageId: 1, sequence: 0, responseCode: 0, payload: Uint8List(300));
      expect(bytes.sublist(4, 6), [0x01, 0x2C]);
    });

    test('refuse a payload that does not fit', () {
      expect(
        () => encodeDirconFrame(messageId: 1, sequence: 0, responseCode: 0, payload: Uint8List(0x10000)),
        throwsArgumentError,
      );
    });

    test('parse one frame', () {
      final frames = DirconFrameParser().add(encodeDirconFrame(messageId: 3, sequence: 5, responseCode: 2, payload: [7]));
      expect(frames, hasLength(1));
      expect(frames.single.messageId, 3);
      expect(frames.single.sequence, 5);
      expect(frames.single.responseCode, 2);
      expect(frames.single.payload, [7]);
    });

    test('parse frames that arrive merged', () {
      final merged = [
        ...encodeDirconFrame(messageId: 1, sequence: 1, responseCode: 0),
        ...encodeDirconFrame(messageId: 2, sequence: 2, responseCode: 0, payload: [1, 2]),
      ];
      final frames = DirconFrameParser().add(merged);
      expect(frames.map((f) => f.messageId), [1, 2]);
    });

    test('parse a frame that arrives a byte at a time', () {
      final bytes = encodeDirconFrame(messageId: 6, sequence: 0, responseCode: 0, payload: [9, 9, 9, 9]);
      final parser = DirconFrameParser();
      final frames = [for (final b in bytes) ...parser.add([b])];
      expect(frames, hasLength(1));
      expect(frames.single.payload, [9, 9, 9, 9]);
      expect(parser.pendingBytes, 0);
    });

    test('keep the start of the next frame until the rest arrives', () {
      final first = encodeDirconFrame(messageId: 1, sequence: 1, responseCode: 0);
      final second = encodeDirconFrame(messageId: 2, sequence: 2, responseCode: 0, payload: [5]);
      final parser = DirconFrameParser();
      expect(parser.add([...first, ...second.sublist(0, 4)]), hasLength(1));
      expect(parser.pendingBytes, 4);
      expect(parser.add(second.sublist(4)).single.payload, [5]);
    });
  });

  group('DirconClientParser', () {
    final uuid = Uint8List.fromList(List.generate(16, (i) => i + 10));
    final body = [...uuid, 1, 2, 3];
    final header = encodeDirconFrame(messageId: 3, sequence: 4, responseCode: 0, payload: body).sublist(0, 6);
    final notification = encodeDirconFrame(messageId: 6, sequence: 2, responseCode: 0, payload: [...uuidToBytes('2ad2'), 7, 8]);
    Uint8List? expected(int seq, int id) => seq == 4 && id == 3 ? uuid : null;

    test('a response whose body arrives after a notification still pairs up, wherever the stream is cut', () {
      final stream = [...header, ...notification, ...body, ...notification];
      for (var cut = 0; cut <= stream.length; cut++) {
        final parser = DirconClientParser(expectedUuid: expected);
        final frames = [...parser.add(stream.sublist(0, cut)), ...parser.add(stream.sublist(cut))];
        expect(frames.map((f) => f.messageId), [6, 3, 6], reason: 'cut at $cut');
        expect(frames[1].payload, body, reason: 'cut at $cut');
        expect(frames[1].sequence, 4);
        expect(parser.pendingBytes, 0);
      }
    });

    test('an ordinary response is untouched', () {
      final frames = DirconClientParser(
        expectedUuid: expected,
      ).add(encodeDirconFrame(messageId: 3, sequence: 4, responseCode: 0, payload: body));
      expect(frames.single.payload, body);
    });

    test('a response nobody is waiting for passes through as it is', () {
      final frames = DirconClientParser(
        expectedUuid: (_, __) => null,
      ).add(encodeDirconFrame(messageId: 3, sequence: 9, responseCode: 0, payload: body));
      expect(frames.single.payload, body);
    });
  });
}
