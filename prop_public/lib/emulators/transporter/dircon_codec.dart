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

/// Reassembles the frames a DirCon *trainer* sends to a client.
///
/// A response to a read, write or notification request starts with the UUID of
/// the characteristic the client asked about. A JetBlack Victory writes the
/// response header first and the body a moment later, and in between it pushes
/// its own notifications, so a whole notification can sit between a response's
/// header and its body. A plain [DirconFrameParser] takes the first bytes of
/// that notification for the body and never finds its footing again.
///
/// This parser asks the caller which UUID a response should open with
/// ([expectedUuid], by sequence number and message id). When the bytes after a
/// header open with a notification instead, it hands the notification out on
/// its own and keeps waiting for the body.
class DirconClientParser {
  DirconClientParser({required this.expectedUuid});

  /// The 16 bytes a response with this sequence and message id should open
  /// with, or null when there is no such request (or it carries no UUID).
  final Uint8List? Function(int sequence, int messageId) expectedUuid;

  static const int _notificationId = 6;

  Uint8List _buffer = Uint8List(0);
  DirconFrame? _awaitingBody;
  Uint8List? _awaitingUuid;

  /// Bytes received that do not yet make up a whole frame.
  int get pendingBytes => _buffer.length;

  /// How many times a notification was found between a header and its body.
  int interleavedNotifications = 0;

  List<DirconFrame> add(List<int> data) {
    if (data.isNotEmpty) {
      final merged = Uint8List(_buffer.length + data.length)
        ..setRange(0, _buffer.length, _buffer)
        ..setRange(_buffer.length, _buffer.length + data.length, data);
      _buffer = merged;
    }
    final frames = <DirconFrame>[];
    var offset = 0;

    int length(int at) => (_buffer[at + 4] << 8) | _buffer[at + 5];

    DirconFrame frameAt(int at, {int? payloadStart, int? payloadLength}) {
      final start = payloadStart ?? at + dirconHeaderLength;
      final size = payloadLength ?? length(at);
      return DirconFrame(
        version: _buffer[at],
        messageId: _buffer[at + 1],
        sequence: _buffer[at + 2],
        responseCode: _buffer[at + 3],
        payload: Uint8List.fromList(_buffer.sublist(start, start + size)),
      );
    }

    bool isNotificationHeader(int at) => _buffer[at] == dirconProtocolVersion && _buffer[at + 1] == _notificationId;

    bool opensWith(int at, Uint8List uuid) {
      for (var i = 0; i < 16; i++) {
        if (_buffer[at + i] != uuid[i]) return false;
      }
      return true;
    }

    while (true) {
      final available = _buffer.length - offset;
      final awaiting = _awaitingBody;

      if (awaiting == null) {
        if (available < dirconHeaderLength) break;
        final size = length(offset);
        final id = _buffer[offset + 1];
        final uuid = id == _notificationId ? null : expectedUuid(_buffer[offset + 2], id);
        if (uuid != null && size >= 16) {
          if (available < dirconHeaderLength + 16) break;
          if (!opensWith(offset + dirconHeaderLength, uuid) && isNotificationHeader(offset + dirconHeaderLength)) {
            // The body is late: remember the header, let the notification through.
            _awaitingBody = frameAt(offset, payloadLength: 0);
            _awaitingUuid = uuid;
            _awaitingLength = size;
            offset += dirconHeaderLength;
            continue;
          }
        }
        if (available < dirconHeaderLength + size) break;
        frames.add(frameAt(offset));
        offset += dirconHeaderLength + size;
        continue;
      }

      // A response header is waiting for its body.
      final uuid = _awaitingUuid!;
      if (available >= 16 && opensWith(offset, uuid)) {
        final size = _awaitingLength;
        if (available < size) break;
        frames.add(
          DirconFrame(
            version: awaiting.version,
            messageId: awaiting.messageId,
            sequence: awaiting.sequence,
            responseCode: awaiting.responseCode,
            payload: Uint8List.fromList(_buffer.sublist(offset, offset + size)),
          ),
        );
        offset += size;
        _awaitingBody = null;
        _awaitingUuid = null;
        continue;
      }
      if (available >= dirconHeaderLength && isNotificationHeader(offset)) {
        final size = length(offset);
        if (available < dirconHeaderLength + size) break;
        frames.add(frameAt(offset));
        interleavedNotifications++;
        offset += dirconHeaderLength + size;
        continue;
      }
      if (available < 16) break;
      // Neither the body nor a notification: give the response up as an empty
      // one rather than wait for ever.
      frames.add(awaiting);
      _awaitingBody = null;
      _awaitingUuid = null;
    }

    if (offset > 0) _buffer = Uint8List.fromList(_buffer.sublist(offset));
    return frames;
  }

  int _awaitingLength = 0;

  void reset() {
    _buffer = Uint8List(0);
    _awaitingBody = null;
    _awaitingUuid = null;
  }
}
