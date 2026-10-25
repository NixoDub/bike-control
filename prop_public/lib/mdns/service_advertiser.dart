import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:prop/mdns/dns_message.dart';
import 'package:prop/mdns/mdns_responder.dart';
import 'package:prop/utils/network_address.dart';
import 'package:prop/utils/prefs.dart';
import 'package:prop/utils/shared.dart';

class AdvertisedService {
  /// Instance name, e.g. 'BikeControl'.
  final String name;

  /// Service type without domain, e.g. '_wahoo-fitness-tnp._tcp'.
  final String type;

  final int port;

  /// The IPv4 address to advertise.
  final InternetAddress address;

  final Map<String, Uint8List> txt;

  /// The mDNS hostname label (without `.local`) to publish the host record
  /// under, or null to derive it from [name].
  final String? hostLabel;

  AdvertisedService({
    required this.name,
    required this.type,
    required this.port,
    required this.address,
    required this.txt,
    this.hostLabel,
  });
}

abstract class ServiceAdvertisement {
  Future<void> unregister();
}

abstract class ServiceAdvertiser {
  /// Process-wide advertiser the emulators use.
  static ServiceAdvertiser instance = platformDefault();

  /// The right backend for the current platform.
  static ServiceAdvertiser platformDefault() {
    if (kIsWeb) return NsdServiceAdvertiser();
    final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    return ResponderServiceAdvertiser(
      announceInterval: desktop
          ? ResponderServiceAdvertiser.desktopAnnounceInterval
          : ResponderServiceAdvertiser.defaultAnnounceInterval,
    );
  }

  Future<ServiceAdvertisement> register(AdvertisedService service);

  /// The IPv4 currently in our advertisements, or null when nothing is
  /// advertised. Backends whose daemon owns the records report
  /// [untrackedAddress].
  ValueListenable<String?> get advertisedAddress => untrackedAddress;

  /// A never-changing null [advertisedAddress] for backends that do not own
  /// their host records.
  static final ValueListenable<String?> untrackedAddress = ValueNotifier<String?>(null);
}

/// Hostname-label rules shared by the backends that publish their own host
/// record.
abstract final class MdnsHostLabel {
  static const String _prefKey = 'mdns_host_label';
  static String? _memoryLabel;

  /// [serviceName] turned into a DNS label: runs of anything outside letters
  /// and digits become one hyphen ("My Trainer - BikeControl" is
  /// "My-Trainer-BikeControl"). Null when nothing usable is left.
  static String? derivedFrom(String serviceName) {
    var label = serviceName.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (label.length > 63) label = label.substring(0, 63).replaceAll(RegExp(r'-+$'), '');
    return label.isEmpty ? null : label;
  }

  /// The stored random label, or a fresh one stored on the spot.
  static String storedRandom() {
    final stored = propPrefs.getString(_prefKey) ?? _memoryLabel;
    if (stored != null && stored.isNotEmpty) {
      _memoryLabel = stored;
      return stored;
    }
    final fresh = 'bikecontrol-${Random().nextInt(1 << 24).toRadixString(16).padLeft(6, '0')}';
    _memoryLabel = fresh;
    propPrefs.setString(_prefKey, fresh);
    return fresh;
  }
}

/// The OS-responder backend (via the `nsd` plugin). Stubbed here.
class NsdServiceAdvertiser implements ServiceAdvertiser {
  @override
  ValueListenable<String?> get advertisedAddress => ServiceAdvertiser.untrackedAddress;

  @override
  Future<ServiceAdvertisement> register(AdvertisedService service) => throw UnimplementedError();
}

/// An in-process multicast DNS responder.
///
/// It answers the queries other devices send for what it advertises, and
/// announces the records unprompted on registration and every
/// [announceInterval]. One UDP socket on port 5353 serves every registration;
/// it is opened with the first and closed with the last.
///
/// Each service gets a host record of its own, named after its hostname label
/// (by default derived from the service name), which is what DirCon clients
/// resolve the SRV target through.
class ResponderServiceAdvertiser implements ServiceAdvertiser {
  static const Duration desktopAnnounceInterval = Duration(seconds: 10);
  static const Duration defaultAnnounceInterval = Duration(seconds: 60);

  final Duration announceInterval;

  ResponderServiceAdvertiser({this.announceInterval = defaultAnnounceInterval});

  static final InternetAddress _group = InternetAddress('224.0.0.251');
  static const int _port = 5353;
  static const int _maxQueryLog = 40;
  static const DnsName _metaQuery = ['_services', '_dns-sd', '_udp', 'local'];

  final List<_Registration> _registrations = [];
  final List<MdnsQueryLogEntry> _queries = [];
  final ValueNotifier<String?> _address = ValueNotifier<String?>(null);
  RawDatagramSocket? _socket;

  /// Test seams: with [debugSink] set nothing touches the network, and every
  /// packet the responder would send goes to the sink instead.
  @visibleForTesting
  void Function(Uint8List bytes, InternetAddress? to, int? port)? debugSink;
  Future<void>? _opening;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _announceTimer;

  /// The hostname label (without `.local`) of the most recently registered
  /// service. Null while nothing is advertised.
  String? get hostLabel => _registrations.isEmpty ? null : _registrations.last.hostLabel;

  /// The hostname label pinned for every registration, or null when each
  /// service derives its own.
  String? get fixedHostLabel => null;

  /// Android only: whether the active responder socket holds the multicast
  /// lock. This build does not take one.
  bool get holdsMulticastLock => false;

  /// The most recent mDNS queries this responder saw.
  List<MdnsQueryLogEntry> get recentQueries => List.unmodifiable(_queries);

  /// Re-reads the LAN address and, if it moved, re-announces every service
  /// under the new one.
  Future<void> refreshAddress() async {
    if (_registrations.isEmpty) return;
    final picked = await AdvertisedAddressPicker.pick();
    if (picked == null) return;
    if (_registrations.every((r) => r.address.address == picked.address)) return;
    for (final registration in _registrations) {
      registration.address = picked;
    }
    _address.value = picked.address;
    _pinEgress(picked);
    for (final registration in List<_Registration>.of(_registrations)) {
      _announce(registration);
    }
  }

  @override
  ValueListenable<String?> get advertisedAddress => _address;

  @override
  Future<ServiceAdvertisement> register(AdvertisedService service) async {
    await _ensureSocket(service.address);
    final label = service.hostLabel ?? MdnsHostLabel.derivedFrom(service.name) ?? MdnsHostLabel.storedRandom();
    final registration = _Registration(service, label);
    _registrations.add(registration);
    _address.value = service.address.address;
    Logger.info('mDNS: advertising ${service.name}.${service.type} at ${service.address.address}:${service.port}');
    _announce(registration);
    _announceTimer ??= Timer.periodic(announceInterval, (_) => unawaited(_tick()));
    return _Advertisement(() => _unregister(registration));
  }

  Future<void> _tick() async {
    try {
      await refreshAddress();
    } catch (e) {
      Logger.warn('mDNS: could not refresh the address: $e');
    }
    for (final registration in List<_Registration>.of(_registrations)) {
      _sendRecords(registration);
    }
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  /// Announces [registration] now and twice more shortly after, as RFC 6762
  /// §8.3 does; a lost first packet is the common failure on Wi-Fi.
  void _announce(_Registration registration) {
    _sendRecords(registration);
    for (final delay in const [Duration(seconds: 1), Duration(seconds: 3)]) {
      Timer(delay, () {
        if (_registrations.contains(registration)) _sendRecords(registration);
      });
    }
  }

  void _sendRecords(_Registration registration, {bool goodbye = false}) {
    final records = registration.allRecords();
    final skipHost = goodbye && _registrations.any((r) => r != registration && r.hostName.join('.') == registration.hostName.join('.'));
    _send(
      buildDnsResponse(
        answers: [
          for (final record in records)
            if (!(skipHost && record.type == dnsTypeA)) goodbye ? record.withTtl(0) : record,
        ],
      ),
    );
  }

  void _send(Uint8List bytes, {InternetAddress? to, int? port}) {
    final sink = debugSink;
    if (sink != null) {
      sink(bytes, to, port);
      return;
    }
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(bytes, to ?? _group, port ?? _port);
    } catch (e) {
      Logger.warn('mDNS: send failed: $e');
    }
  }

  // ── Receiving ─────────────────────────────────────────────────────────────

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      try {
        handleDatagram(datagram!.data, datagram.address, datagram.port);
      } catch (e, s) {
        Logger.recordError('mDNS: could not handle a packet', e, s);
      }
    }
  }

  /// Answers the mDNS query in [packet], if it asks about what is advertised.
  /// Public so the packet logic can be driven without a socket.
  @visibleForTesting
  void handleDatagram(Uint8List packet, InternetAddress source, int sourcePort) {
    final query = parseDnsQuery(packet);
    if (query == null || query.isResponse || _registrations.isEmpty) return;

    final answers = <String, DnsRecord>{};
    final additional = <String, DnsRecord>{};
    for (final question in query.questions) {
      for (final registration in _registrations) {
        registration.collect(question, answers, additional);
      }
      if (dnsNamesEqual(question.name, _metaQuery) && (question.type == dnsTypePtr || question.type == dnsTypeAny)) {
        for (final registration in _registrations) {
          final meta = dnsPtr(_metaQuery, registration.typeName);
          answers[meta.key + registration.typeName.join('.')] = meta;
        }
      }
    }
    additional.removeWhere((key, _) => answers.containsKey(key));

    // A resolver that is not itself a multicast DNS stack (source port other
    // than 5353) wants a unicast reply that repeats its question.
    final legacyUnicast = sourcePort != _port;
    final entry = _logQuery(query, source, sourcePort);
    if (answers.isEmpty) return;
    if (legacyUnicast) {
      entry.answeredUnicast = true;
      List<DnsRecord> plain(Iterable<DnsRecord> records) => [
        for (final r in records) DnsRecord(name: r.name, type: r.type, ttl: min(r.ttl, 10), rdata: r.rdata),
      ];
      _send(
        buildDnsResponse(
          answers: plain(answers.values),
          additional: plain(additional.values),
          id: query.id,
          questions: query.questions,
        ),
        to: source,
        port: sourcePort,
      );
    } else {
      entry.answeredMulticast = true;
      _send(buildDnsResponse(answers: answers.values.toList(), additional: additional.values.toList()));
    }
  }

  MdnsQueryLogEntry _logQuery(DnsQuery query, InternetAddress source, int sourcePort) {
    final questions = [for (final q in query.questions) '${dnsTypeName(q.type)} ${q.name.join('.')}'];
    final last = _queries.isEmpty ? null : _queries.last;
    if (last != null &&
        last.source == source.address &&
        last.sourcePort == sourcePort &&
        listEquals(last.questions, questions)) {
      last.at = DateTime.now();
      last.count++;
      return last;
    }
    final entry = MdnsQueryLogEntry(
      at: DateTime.now(),
      source: source.address,
      sourcePort: sourcePort,
      wantsUnicast: query.questions.any((q) => q.unicastResponse),
      questions: questions,
      answeredUnicast: false,
      answeredMulticast: false,
      duringOwnBrowse: OwnMdnsBrowsing.isBrowsing,
    );
    _queries.add(entry);
    if (_queries.length > _maxQueryLog) _queries.removeAt(0);
    return entry;
  }

  // ── Socket ────────────────────────────────────────────────────────────────

  Future<void> _ensureSocket(InternetAddress address) async {
    if (debugSink != null) return;
    if (_socket == null) {
      final opening = _opening ??= _open();
      try {
        await opening;
      } finally {
        if (identical(_opening, opening)) _opening = null;
      }
    }
    _pinEgress(address);
  }

  Future<void> _open() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _port,
      reuseAddress: true,
      // Windows has no SO_REUSEPORT; SO_REUSEADDR alone shares the port there.
      reusePort: !Platform.isWindows,
      ttl: 255,
    );
    socket.multicastLoopback = true;
    socket.multicastHops = 255;
    var joined = 0;
    try {
      for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        try {
          socket.joinMulticast(_group, interface);
          joined++;
        } catch (_) {
          // An adapter that cannot join (down, virtual) is simply skipped.
        }
      }
      if (joined == 0) socket.joinMulticast(_group);
    } catch (e) {
      socket.close();
      rethrow;
    }
    _subscription = socket.listen(_onEvent, onError: (Object _) {}, cancelOnError: false);
    _socket = socket;
  }

  /// Sends multicast out of the adapter that carries [address], not whichever
  /// one the routing table prefers (a VPN or virtual switch often wins that).
  void _pinEgress(InternetAddress address) {
    try {
      _socket?.setRawOption(
        RawSocketOption(
          RawSocketOption.levelIPv4,
          RawSocketOption.IPv4MulticastInterface,
          Uint8List.fromList(address.rawAddress),
        ),
      );
    } catch (e) {
      Logger.warn('mDNS: could not pin the multicast interface: $e');
    }
  }

  Future<void> _unregister(_Registration registration) async {
    if (!_registrations.remove(registration)) return;
    _sendRecords(registration, goodbye: true);
    if (_registrations.isNotEmpty) return;
    _announceTimer?.cancel();
    _announceTimer = null;
    _address.value = null;
    if (debugSink != null) return;
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }
}

class _Advertisement implements ServiceAdvertisement {
  _Advertisement(this._unregister);

  final Future<void> Function() _unregister;

  @override
  Future<void> unregister() => _unregister();
}

/// What one registered service puts on the wire.
class _Registration {
  _Registration(this.service, this.hostLabel) : address = service.address;

  final AdvertisedService service;
  final String hostLabel;
  InternetAddress address;

  late final DnsName typeName = [...service.type.split('.'), 'local'];
  late final DnsName instanceName = [service.name, ...typeName];
  late final DnsName hostName = [hostLabel, 'local'];

  DnsRecord get ptr => dnsPtr(typeName, instanceName);
  DnsRecord get srv => dnsSrv(instanceName, hostName, service.port);
  DnsRecord get txt => dnsTxt(instanceName, service.txt);
  DnsRecord get a => dnsA(hostName, address.rawAddress);

  List<DnsRecord> allRecords() => [ptr, srv, txt, a];

  void collect(DnsQuestion q, Map<String, DnsRecord> answers, Map<String, DnsRecord> additional) {
    final type = q.type;
    void answer(DnsRecord r) => answers['${r.key}|${instanceName.join('.')}'] = r;
    void extra(DnsRecord r) => additional['${r.key}|${instanceName.join('.')}'] = r;

    if (dnsNamesEqual(q.name, typeName) && (type == dnsTypePtr || type == dnsTypeAny)) {
      answer(ptr);
      extra(srv);
      extra(txt);
      extra(a);
    } else if (dnsNamesEqual(q.name, instanceName)) {
      if (type == dnsTypeSrv || type == dnsTypeAny) {
        answer(srv);
        extra(a);
      }
      if (type == dnsTypeTxt || type == dnsTypeAny) answer(txt);
    } else if (dnsNamesEqual(q.name, hostName) && (type == dnsTypeA || type == dnsTypeAny)) {
      answer(a);
    }
  }
}
