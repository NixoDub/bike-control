import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:prop/emulators/ble_definition.dart';
import 'package:prop/emulators/transporter/dircon_codec.dart';
import 'package:prop/emulators/transporter/transporter.dart';
import 'package:prop/utils/constants.dart';
import 'package:prop/utils/shared.dart';
import 'package:prop/utils/uuid.dart';
import 'package:universal_ble/universal_ble.dart';

/// Exposes a [BleDefinition] to one client over a TCP socket speaking DirCon:
/// the client discovers the definition's services and characteristics, reads
/// and writes them, and enables notifications; the definition pushes
/// notifications back through [sendCharacteristicNotification].
class NetworkTransporter extends Transporter {
  NetworkTransporter({this.socket, required super.definition});

  Socket? socket;

  final DirconFrameParser _parser = DirconFrameParser();
  final Set<String> _notifying = {};
  Future<void> _queue = Future<void>.value();
  bool _disposed = false;

  /// The characteristics (normalized UUIDs) the client enabled notifications on.
  Set<String> get notifyingCharacteristics => Set.unmodifiable(_notifying);

  /// Feeds bytes read off the socket in. Requests are answered one at a time,
  /// in the order they arrived, even when answering one (a read) takes a while.
  void handleIncomingData(List<int> data) {
    if (_disposed) return;
    for (final frame in _parser.add(data)) {
      _queue = _queue.then((_) => _handleFrame(frame)).catchError((Object e, StackTrace s) {
        Logger.recordError('DirCon: failed to answer $frame', e, s);
      });
    }
  }

  Future<void> _handleFrame(DirconFrame frame) async {
    if (_disposed) return;
    if (frame.version != dirconProtocolVersion) {
      _respond(frame, FtmsMdnsConstants.DC_RC_UNKNOWN_PROTOCOL_VERSION);
      return;
    }
    try {
      switch (frame.messageId) {
        case FtmsMdnsConstants.DC_MESSAGE_DISCOVER_SERVICES:
          _discoverServices(frame);
        case FtmsMdnsConstants.DC_MESSAGE_DISCOVER_CHARACTERISTICS:
          _discoverCharacteristics(frame);
        case FtmsMdnsConstants.DC_MESSAGE_READ_CHARACTERISTIC:
          await _read(frame);
        case FtmsMdnsConstants.DC_MESSAGE_WRITE_CHARACTERISTIC:
          _write(frame);
        case FtmsMdnsConstants.DC_MESSAGE_ENABLE_CHARACTERISTIC_NOTIFICATIONS:
          _enableNotifications(frame);
        default:
          Logger.trace(() => 'DirCon: unknown message ${frame.messageId}');
          _respond(frame, FtmsMdnsConstants.DC_RC_UNKNOWN_MESSAGE_TYPE);
      }
    } catch (e, s) {
      Logger.recordError('DirCon: message ${frame.messageId} failed', e, s);
      _respond(frame, FtmsMdnsConstants.DC_RC_UNEXPECTED_ERROR);
    }
  }

  List<String> get _serviceUuids => definition.serviceUUIDs.map(normalizeUuid).toList();

  void _discoverServices(DirconFrame frame) {
    final payload = BytesBuilder(copy: false);
    final services = _serviceUuids;
    for (final service in services) {
      payload.add(uuidToBytes(service));
    }
    Logger.trace(() => 'DirCon: discover services -> ${services.length}');
    _respond(frame, FtmsMdnsConstants.DC_RC_REQUEST_COMPLETED_SUCCESSFULLY, payload.toBytes());
  }

  void _discoverCharacteristics(DirconFrame frame) {
    if (frame.payload.length < 16) {
      _respond(frame, FtmsMdnsConstants.DC_RC_UNEXPECTED_ERROR);
      return;
    }
    final serviceBytes = frame.payload.sublist(0, 16);
    final service = uuidFromBytes(serviceBytes);
    if (!_serviceUuids.contains(service)) {
      Logger.trace(() => 'DirCon: discover characteristics of unknown service $service');
      _respond(frame, FtmsMdnsConstants.DC_RC_SERVICE_NOT_FOUND, serviceBytes);
      return;
    }
    final payload = BytesBuilder(copy: false)..add(serviceBytes);
    final characteristics = definition.getCharacteristics(service);
    for (final characteristic in characteristics) {
      payload.add(uuidToBytes(characteristic.uuid));
      payload.addByte(propertyByteOf(characteristic));
    }
    Logger.trace(() => 'DirCon: discover characteristics of $service -> ${characteristics.length}');
    _respond(frame, FtmsMdnsConstants.DC_RC_REQUEST_COMPLETED_SUCCESSFULLY, payload.toBytes());
  }

  Future<void> _read(DirconFrame frame) async {
    if (frame.payload.length < 16) {
      _respond(frame, FtmsMdnsConstants.DC_RC_UNEXPECTED_ERROR);
      return;
    }
    final uuidBytes = frame.payload.sublist(0, 16);
    final characteristic = uuidFromBytes(uuidBytes);
    final properties = _propertiesOf(characteristic);
    if (properties == null) {
      _respond(frame, FtmsMdnsConstants.DC_RC_CHARACTERISTIC_NOT_FOUND, uuidBytes);
      return;
    }
    final read = definition.onReadRequest(characteristic);
    if (read == null) {
      _respond(frame, FtmsMdnsConstants.DC_RC_CHARACTERISTIC_OPERATION_NOT_SUPPORTED, uuidBytes);
      return;
    }
    final value = await read;
    Logger.trace(() => 'DirCon: read $characteristic -> ${bytesToHex(value)}');
    _respond(frame, FtmsMdnsConstants.DC_RC_REQUEST_COMPLETED_SUCCESSFULLY, [...uuidBytes, ...value]);
  }

  void _write(DirconFrame frame) {
    if (frame.payload.length < 16) {
      _respond(frame, FtmsMdnsConstants.DC_RC_CHARACTERISTIC_WRITE_FAILED_INVALID_SIZE);
      return;
    }
    final uuidBytes = frame.payload.sublist(0, 16);
    final characteristic = uuidFromBytes(uuidBytes);
    if (_propertiesOf(characteristic) == null) {
      _respond(frame, FtmsMdnsConstants.DC_RC_CHARACTERISTIC_NOT_FOUND, uuidBytes);
      return;
    }
    final value = frame.payload.sublist(16);
    Logger.trace(() => 'DirCon: write $characteristic <- ${bytesToHex(value)}');
    definition.onWriteRequest(characteristic, value);
    _respond(frame, FtmsMdnsConstants.DC_RC_REQUEST_COMPLETED_SUCCESSFULLY, uuidBytes);
  }

  void _enableNotifications(DirconFrame frame) {
    if (frame.payload.length < 17) {
      _respond(frame, FtmsMdnsConstants.DC_RC_UNEXPECTED_ERROR);
      return;
    }
    final uuidBytes = frame.payload.sublist(0, 16);
    final characteristic = uuidFromBytes(uuidBytes);
    if (_propertiesOf(characteristic) == null) {
      _respond(frame, FtmsMdnsConstants.DC_RC_CHARACTERISTIC_NOT_FOUND, uuidBytes);
      return;
    }
    final enable = frame.payload[16] != 0;
    Logger.trace(() => 'DirCon: notifications $characteristic ${enable ? 'on' : 'off'}');
    if (enable) {
      _notifying.add(characteristic);
      definition.onEnableNotificationRequest(characteristic);
    } else {
      _notifying.remove(characteristic);
    }
    _respond(frame, FtmsMdnsConstants.DC_RC_REQUEST_COMPLETED_SUCCESSFULLY, uuidBytes);
  }

  /// The properties of [characteristic] (a normalized UUID) in whichever of the
  /// definition's services carries it, or null when none does.
  List<CharacteristicProperty>? _propertiesOf(String characteristic) {
    for (final service in definition.serviceUUIDs) {
      for (final candidate in definition.getCharacteristics(service)) {
        if (normalizeUuid(candidate.uuid) == characteristic) return candidate.properties;
      }
    }
    return null;
  }

  void _respond(DirconFrame request, int responseCode, [List<int> payload = const []]) {
    _send(
      encodeDirconFrame(
        messageId: request.messageId,
        sequence: request.sequence,
        responseCode: responseCode,
        payload: payload,
      ),
    );
  }

  @override
  void sendCharacteristicNotification(String characteristicUUID, List<int> data, {int responseCode = 1}) {
    if (_disposed) return;
    final characteristic = normalizeUuid(characteristicUUID);
    // A client only hears about what it asked to hear about.
    if (!_notifying.contains(characteristic)) return;
    Logger.trace(() => 'DirCon: notify $characteristic -> ${bytesToHex(data)}', record: false);
    _send(
      encodeDirconFrame(
        messageId: FtmsMdnsConstants.DC_MESSAGE_CHARACTERISTIC_NOTIFICATION,
        sequence: 0,
        responseCode: responseCode,
        payload: [...uuidToBytes(characteristic), ...data],
      ),
    );
  }

  void _send(Uint8List bytes) {
    final socket = this.socket;
    if (socket == null) return;
    try {
      socket.add(bytes);
    } catch (_) {
      // The socket is closing; the server reports the disconnect.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _notifying.clear();
    _parser.reset();
    super.dispose();
  }

  /// The DirCon property byte of [characteristic]: 1 read, 2 write, 4 notify.
  /// Indicate rides on the notify bit and write-without-response on write,
  /// since DirCon carries neither distinction.
  static int propertyByteOf(BleCharacteristic characteristic) {
    var value = 0;
    for (final property in characteristic.properties) {
      switch (property) {
        case CharacteristicProperty.read:
          value |= 0x01;
        case CharacteristicProperty.write || CharacteristicProperty.writeWithoutResponse:
          value |= 0x02;
        case CharacteristicProperty.notify || CharacteristicProperty.indicate:
          value |= 0x04;
        default:
          break;
      }
    }
    return value;
  }
}
