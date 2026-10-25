import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:prop/emulators/transporter/dircon_codec.dart';
import 'package:prop/transports/trainer_transport.dart';
import 'package:prop/utils/constants.dart';
import 'package:prop/utils/shared.dart';
import 'package:prop/utils/uuid.dart';
import 'package:universal_ble/universal_ble.dart';

/// [TrainerTransport] over a DirCon TCP connection: the client side of what
/// [NetworkTransporter] serves. A trainer that advertises
/// `_wahoo-fitness-tnp._tcp` (a Wahoo, a Tacx, a JetBlack...) carries its GATT
/// services over this socket, so the bridge can treat it like a BLE trainer.
class DirconTrainerTransport extends TrainerTransport {
  DirconTrainerTransport({required String id, required this.host, required this.port}) : _id = id;

  /// How long one request waits for its answer.
  static const Duration requestTimeout = Duration(seconds: 5);
  static const Duration connectTimeout = Duration(seconds: 8);

  final String _id;
  final String host;
  final int port;

  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSub;
  final DirconFrameParser _parser = DirconFrameParser();
  final Map<int, Completer<DirconFrame>> _pending = {};
  final StreamController<({String characteristic, Uint8List value})> _notifications = StreamController.broadcast();
  int _sequence = 0;
  bool _closing = false;

  @override
  String get id => _id;

  bool get isConnected => _socket != null;

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    _closing = false;
    final address = await _resolve();
    final socket = await Socket.connect(address, port, timeout: connectTimeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _parser.reset();
    _socketSub = socket.listen(_onData, onError: (Object e, StackTrace s) => _onClosed(), onDone: _onClosed);
    Logger.trace(() => 'DirCon client: connected to ${address.address}:$port');
  }

  /// IPv4 first: the trainer's `.local` name often resolves to a link-local
  /// IPv6 address a plain socket cannot use.
  Future<InternetAddress> _resolve() async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return literal;
    final v4 = await InternetAddress.lookup(host, type: InternetAddressType.IPv4).catchError((_) => <InternetAddress>[]);
    if (v4.isNotEmpty) return v4.first;
    final any = await InternetAddress.lookup(host);
    if (any.isEmpty) throw SocketException('Cannot resolve $host');
    return any.first;
  }

  void _onData(Uint8List data) {
    for (final frame in _parser.add(data)) {
      if (frame.messageId == FtmsMdnsConstants.DC_MESSAGE_CHARACTERISTIC_NOTIFICATION) {
        if (frame.payload.length >= 16) {
          _notifications.add((
            characteristic: uuidFromBytes(frame.payload.sublist(0, 16)),
            value: Uint8List.fromList(frame.payload.sublist(16)),
          ));
        }
        continue;
      }
      final waiting = _pending.remove(frame.sequence);
      if (waiting != null && !waiting.isCompleted) waiting.complete(frame);
    }
  }

  void _onClosed() {
    final dropped = !_closing && _socket != null;
    _teardown();
    if (dropped) {
      Logger.trace(() => 'DirCon client: connection to $host:$port lost');
      onDisconnected?.call();
    }
  }

  void _teardown() {
    _socketSub?.cancel();
    _socketSub = null;
    _socket?.destroy();
    _socket = null;
    for (final waiting in _pending.values) {
      if (!waiting.isCompleted) waiting.completeError(const SocketException('DirCon connection closed'));
    }
    _pending.clear();
  }

  Future<DirconFrame> _request(int messageId, [List<int> payload = const []]) {
    final socket = _socket;
    if (socket == null) return Future.error(const SocketException('DirCon not connected'));
    var sequence = (++_sequence) & 0xff;
    while (_pending.containsKey(sequence)) {
      sequence = (++_sequence) & 0xff;
    }
    final completer = _pending[sequence] = Completer<DirconFrame>();
    socket.add(encodeDirconFrame(messageId: messageId, sequence: sequence, responseCode: 0, payload: payload));
    return completer.future.timeout(
      requestTimeout,
      onTimeout: () {
        _pending.remove(sequence);
        throw TimeoutException('DirCon request $messageId timed out', requestTimeout);
      },
    );
  }

  Future<DirconFrame> _expectOk(int messageId, List<int> payload) async {
    final response = await _request(messageId, payload);
    if (response.responseCode != FtmsMdnsConstants.DC_RC_REQUEST_COMPLETED_SUCCESSFULLY) {
      throw StateError('DirCon request $messageId failed with code ${response.responseCode}');
    }
    return response;
  }

  @override
  Future<List<BleService>> discoverServices() async {
    final response = await _expectOk(FtmsMdnsConstants.DC_MESSAGE_DISCOVER_SERVICES, const []);
    final services = <BleService>[];
    for (var i = 0; i + 16 <= response.payload.length; i += 16) {
      final uuid = uuidFromBytes(response.payload.sublist(i, i + 16));
      final characteristics = await _discoverCharacteristics(uuid);
      services.add(BleService(uuid, characteristics));
    }
    return services;
  }

  Future<List<BleCharacteristic>> _discoverCharacteristics(String service) async {
    final response = await _expectOk(FtmsMdnsConstants.DC_MESSAGE_DISCOVER_CHARACTERISTICS, uuidToBytes(service));
    final out = <BleCharacteristic>[];
    // 16 bytes of service uuid, then 17 per characteristic: uuid + property byte.
    for (var i = 16; i + 17 <= response.payload.length; i += 17) {
      final uuid = uuidFromBytes(response.payload.sublist(i, i + 16));
      out.add(BleCharacteristic(uuid, _propertiesOf(response.payload[i + 16]), []));
    }
    return out;
  }

  static List<CharacteristicProperty> _propertiesOf(int byte) => [
    if (byte & 0x01 != 0) CharacteristicProperty.read,
    if (byte & 0x02 != 0) CharacteristicProperty.write,
    if (byte & 0x04 != 0) CharacteristicProperty.notify,
  ];

  @override
  Future<Uint8List> read(String service, String characteristic) async {
    final response = await _expectOk(FtmsMdnsConstants.DC_MESSAGE_READ_CHARACTERISTIC, uuidToBytes(characteristic));
    return Uint8List.fromList(response.payload.length > 16 ? response.payload.sublist(16) : const []);
  }

  /// DirCon has no write-without-response: every write is answered.
  @override
  Future<void> write(String service, String characteristic, Uint8List bytes, {bool withoutResponse = false}) async {
    await _expectOk(FtmsMdnsConstants.DC_MESSAGE_WRITE_CHARACTERISTIC, [...uuidToBytes(characteristic), ...bytes]);
  }

  /// DirCon does not tell notifications from indications either.
  @override
  Future<void> subscribe(String service, String characteristic, {required bool indicate}) async {
    await _expectOk(FtmsMdnsConstants.DC_MESSAGE_ENABLE_CHARACTERISTIC_NOTIFICATIONS, [
      ...uuidToBytes(characteristic),
      1,
    ]);
  }

  @override
  Stream<({String characteristic, Uint8List value})> get notifications => _notifications.stream;

  @override
  Future<void> disconnect() async {
    _closing = true;
    final socket = _socket;
    _teardown();
    try {
      await socket?.close();
    } catch (_) {
      // already gone
    }
  }
}
