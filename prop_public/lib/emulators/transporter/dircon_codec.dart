import 'dart:typed_data';

/// The DirCon (Direct Connect) wire format: a 6-byte header followed by a
/// payload. DirCon is a plain TCP carriage of GATT operations, so a trainer
/// app can talk to a Bluetooth trainer over the network.
///
/// ```
/// byte 0    protocol version (1)
/// byte 1    message id (see FtmsMdnsConstants.DC_MESSAGE_*)
/// byte 2    sequence number (a response echoes its request's)
/// byte 3    response code (0 in a request)
/// byte 4-5  payload length, big endian
/// ```
const int dirconProtocolVersion = 1;
const int dirconHeaderLength = 6;

class DirconFrame {
  const DirconFrame({
    required this.version,
    required this.messageId,
    required this.sequence,
    required this.responseCode,
    required this.payload,
  });

  final int version;
  final int messageId;
  final int sequence;
  final int responseCode;
  final Uint8List payload;

  @override
  String toString() => 'DirconFrame(id: $messageId, seq: $sequence, rc: $responseCode, ${payload.length} bytes)';
}

Uint8List encodeDirconFrame({
  required int messageId,
  required int sequence,
  required int responseCode,
  List<int> payload = const [],
  int version = dirconProtocolVersion,
}) {
  if (payload.length > 0xffff) throw ArgumentError.value(payload.length, 'payload.length', 'Too long for DirCon');
  final out = Uint8List(dirconHeaderLength + payload.length);
  out[0] = version;
  out[1] = messageId;
  out[2] = sequence & 0xff;
  out[3] = responseCode;
  out[4] = (payload.length >> 8) & 0xff;
  out[5] = payload.length & 0xff;
  out.setRange(dirconHeaderLength, out.length, payload);
  return out;
}

/// Reassembles [DirconFrame]s from a TCP byte stream, which can split or merge
/// frames at any point.
class DirconFrameParser {
  Uint8List _buffer = Uint8List(0);

  /// Bytes received that do not yet make up a whole frame.
  int get pendingBytes => _buffer.length;

  /// Feeds [data] in and returns every frame it completed, oldest first.
  List<DirconFrame> add(List<int> data) {
    if (data.isNotEmpty) {
      final merged = Uint8List(_buffer.length + data.length)
        ..setRange(0, _buffer.length, _buffer)
        ..setRange(_buffer.length, _buffer.length + data.length, data);
      _buffer = merged;
    }
    final frames = <DirconFrame>[];
    var offset = 0;
    while (_buffer.length - offset >= dirconHeaderLength) {
      final length = (_buffer[offset + 4] << 8) | _buffer[offset + 5];
      if (_buffer.length - offset < dirconHeaderLength + length) break;
      frames.add(
        DirconFrame(
          version: _buffer[offset],
          messageId: _buffer[offset + 1],
          sequence: _buffer[offset + 2],
          responseCode: _buffer[offset + 3],
          payload: Uint8List.fromList(_buffer.sublist(offset + dirconHeaderLength, offset + dirconHeaderLength + length)),
        ),
      );
      offset += dirconHeaderLength + length;
    }
    if (offset > 0) _buffer = Uint8List.fromList(_buffer.sublist(offset));
    return frames;
  }

  void reset() => _buffer = Uint8List(0);
}
