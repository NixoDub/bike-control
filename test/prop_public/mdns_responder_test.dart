// The mDNS responder's packet logic, driven without a socket: what it
// announces, what it answers to which question, and how.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prop/mdns/dns_message.dart';
import 'package:prop/mdns/service_advertiser.dart';

typedef Sent = ({Uint8List bytes, InternetAddress? to, int? port});

Uint8List query(
  List<String> name,
  int type, {
  bool unicast = false,
  int id = 0,
  bool response = false,
}) {
  final out = BytesBuilder()
    ..add([(id >> 8) & 0xff, id & 0xff, response ? 0x84 : 0x00, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
    ..add(encodeDnsName(name))
    ..add([(type >> 8) & 0xff, type & 0xff, unicast ? 0x80 : 0x00, 0x01]);
  return out.toBytes();
}

const typeName = ['_wahoo-fitness-tnp', '_tcp', 'local'];

void main() {
  late ResponderServiceAdvertiser responder;
  late List<Sent> sent;
  final source = InternetAddress('192.168.1.77');

  AdvertisedService service({String name = 'JetBlack Victory - BikeControl', String? hostLabel}) => AdvertisedService(
    name: name,
    type: '_wahoo-fitness-tnp._tcp',
    port: 36868,
    address: InternetAddress('192.168.1.50'),
    hostLabel: hostLabel,
    txt: {
      'serial-number': Uint8List.fromList('123456789'.codeUnits),
      'ble-service-uuids': Uint8List.fromList('0x1826,0x1818'.codeUnits),
    },
  );

  setUp(() {
    responder = ResponderServiceAdvertiser();
    sent = [];
    responder.debugSink = (bytes, to, port) => sent.add((bytes: bytes, to: to, port: port));
  });

  DnsMessage decode(Sent s) => parseDnsMessage(s.bytes)!;

  List<String> instance(String name) => [name, ...typeName];

  group('announcing', () {
    test('sends PTR, SRV, TXT and A for the service', () async {
      await responder.register(service());
      final message = decode(sent.first);
      expect(message.id, 0);
      expect(message.flags & 0x8000, isNot(0), reason: 'a response');
      final byType = {for (final r in message.answers) r.type: r};
      expect(byType.keys, containsAll([dnsTypePtr, dnsTypeSrv, dnsTypeTxt, dnsTypeA]));

      expect(byType[dnsTypePtr]!.name, typeName);
      expect(dnsPtrTarget(byType[dnsTypePtr]!), instance('JetBlack Victory - BikeControl'));

      final srv = dnsSrvData(byType[dnsTypeSrv]!);
      expect(srv.port, 36868);
      expect(srv.target, ['JetBlack-Victory-BikeControl', 'local']);

      expect(dnsTxtData(byType[dnsTypeTxt]!), {'serial-number': '123456789', 'ble-service-uuids': '0x1826,0x1818'});

      expect(byType[dnsTypeA]!.name, ['JetBlack-Victory-BikeControl', 'local']);
      expect(byType[dnsTypeA]!.rdata, [192, 168, 1, 50]);
    });

    test('the unique records carry the cache-flush bit, the shared PTR does not', () async {
      await responder.register(service());
      final byType = {for (final r in decode(sent.first).answers) r.type: r};
      expect(byType[dnsTypePtr]!.cacheFlush, isFalse);
      expect(byType[dnsTypeSrv]!.cacheFlush, isTrue);
      expect(byType[dnsTypeTxt]!.cacheFlush, isTrue);
      expect(byType[dnsTypeA]!.cacheFlush, isTrue);
    });

    test('an explicit host label wins over the derived one', () async {
      await responder.register(service(hostLabel: 'my-pc'));
      final srv = dnsSrvData(decode(sent.first).answers.firstWhere((r) => r.type == dnsTypeSrv));
      expect(srv.target, ['my-pc', 'local']);
      expect(responder.hostLabel, 'my-pc');
    });

    test('a dot in the instance name stays inside one label', () async {
      await responder.register(service(name: 'Trainer v1.2 - BikeControl'));
      final ptr = decode(sent.first).answers.firstWhere((r) => r.type == dnsTypePtr);
      expect(dnsPtrTarget(ptr), ['Trainer v1.2 - BikeControl', ...typeName]);
    });

    test('says goodbye, with a zero TTL, when unregistered', () async {
      final advertisement = await responder.register(service());
      sent.clear();
      await advertisement.unregister();
      final goodbye = decode(sent.single);
      expect(goodbye.answers, isNotEmpty);
      expect(goodbye.answers.every((r) => r.ttl == 0), isTrue);
      expect(responder.hostLabel, isNull);
    });

    test('publishes the address it advertises', () async {
      expect(responder.advertisedAddress.value, isNull);
      final advertisement = await responder.register(service());
      expect(responder.advertisedAddress.value, '192.168.1.50');
      await advertisement.unregister();
      expect(responder.advertisedAddress.value, isNull);
    });
  });

  group('answering queries', () {
    setUp(() async {
      await responder.register(service());
      sent.clear();
    });

    test('a PTR query for the service type gets the PTR, with SRV, TXT and A alongside', () {
      responder.handleDatagram(query(typeName, dnsTypePtr), source, 5353);
      final message = decode(sent.single);
      expect(sent.single.to, isNull, reason: 'multicast');
      expect(message.id, 0);
      expect(message.answers.map((r) => r.type), [dnsTypePtr]);
      expect(message.additional.map((r) => r.type), containsAll([dnsTypeSrv, dnsTypeTxt, dnsTypeA]));
    });

    test('an SRV query for the instance gets the SRV with the address alongside', () {
      responder.handleDatagram(query(instance('JetBlack Victory - BikeControl'), dnsTypeSrv), source, 5353);
      final message = decode(sent.single);
      expect(message.answers.map((r) => r.type), [dnsTypeSrv]);
      expect(message.additional.map((r) => r.type), [dnsTypeA]);
    });

    test('names are matched without regard to case', () {
      responder.handleDatagram(query(['_WAHOO-fitness-TNP', '_tcp', 'LOCAL'], dnsTypePtr), source, 5353);
      expect(sent, hasLength(1));
    });

    test('an A query for the host name gets the address', () {
      responder.handleDatagram(query(['JetBlack-Victory-BikeControl', 'local'], dnsTypeA), source, 5353);
      final message = decode(sent.single);
      expect(message.answers.single.rdata, [192, 168, 1, 50]);
    });

    test('an ANY query for the instance gets SRV and TXT', () {
      responder.handleDatagram(query(instance('JetBlack Victory - BikeControl'), dnsTypeAny), source, 5353);
      expect(decode(sent.single).answers.map((r) => r.type), containsAll([dnsTypeSrv, dnsTypeTxt]));
    });

    test('the DNS-SD meta query lists the service type', () {
      responder.handleDatagram(query(['_services', '_dns-sd', '_udp', 'local'], dnsTypePtr), source, 5353);
      final answer = decode(sent.single).answers.single;
      expect(dnsPtrTarget(answer), typeName);
    });

    test('a question about something else is not answered', () {
      responder.handleDatagram(query(['_airplay', '_tcp', 'local'], dnsTypePtr), source, 5353);
      responder.handleDatagram(query(['somebody-else', 'local'], dnsTypeA), source, 5353);
      expect(sent, isEmpty);
    });

    test('a response, or garbage, is not answered', () {
      responder.handleDatagram(query(typeName, dnsTypePtr, response: true), source, 5353);
      responder.handleDatagram(Uint8List.fromList([1, 2, 3]), source, 5353);
      responder.handleDatagram(Uint8List(0), source, 5353);
      expect(sent, isEmpty);
    });

    test('a resolver that is not an mDNS stack gets a unicast reply that echoes its question', () {
      responder.handleDatagram(query(typeName, dnsTypePtr, id: 0x1234), source, 49152);
      final reply = sent.single;
      expect(reply.to, source);
      expect(reply.port, 49152);
      final message = decode(reply);
      expect(message.id, 0x1234);
      expect(message.questions.single.type, dnsTypePtr);
      expect(message.answers.every((r) => r.ttl <= 10), isTrue);
      expect(message.answers.every((r) => !r.cacheFlush), isTrue);
    });

    test('a truncated packet does not throw', () {
      final good = query(typeName, dnsTypePtr);
      for (var cut = 0; cut < good.length; cut++) {
        responder.handleDatagram(Uint8List.sublistView(good, 0, cut), source, 5353);
      }
    });
  });

  group('the query log', () {
    setUp(() async {
      await responder.register(service());
      sent.clear();
    });

    test('folds repeats of the same query into one entry', () {
      responder.handleDatagram(query(typeName, dnsTypePtr), source, 5353);
      responder.handleDatagram(query(typeName, dnsTypePtr), source, 5353);
      expect(responder.recentQueries, hasLength(1));
      expect(responder.recentQueries.single.count, 2);
      expect(responder.recentQueries.single.questions, ['PTR _wahoo-fitness-tnp._tcp.local']);
      expect(responder.recentQueries.single.reply, 'multicast');
    });

    test('records an unanswered query as such, and a QU bit as a wish for unicast', () {
      responder.handleDatagram(query(['nothing', 'local'], dnsTypeA, unicast: true), source, 5353);
      final entry = responder.recentQueries.single;
      expect(entry.reply, 'no match');
      expect(entry.wantsUnicast, isTrue);
      expect(entry.source, '192.168.1.77');
    });
  });

  group('host labels', () {
    test('are derived from the service name', () {
      expect(MdnsHostLabel.derivedFrom('BikeControl'), 'BikeControl');
      expect(MdnsHostLabel.derivedFrom('KICKR CORE 73D3 - BikeControl'), 'KICKR-CORE-73D3-BikeControl');
      expect(MdnsHostLabel.derivedFrom('  --Trainer__1--  '), 'Trainer-1');
      expect(MdnsHostLabel.derivedFrom('---'), isNull);
      expect(MdnsHostLabel.derivedFrom(''), isNull);
    });

    test('stay within the 63 characters a DNS label allows', () {
      final label = MdnsHostLabel.derivedFrom('a' * 100)!;
      expect(label.length, 63);
    });

    test('a stored random label is stable and a valid label', () {
      final first = MdnsHostLabel.storedRandom();
      expect(MdnsHostLabel.storedRandom(), first);
      expect(RegExp(r'^[a-z0-9-]{1,63}$').hasMatch(first), isTrue);
    });
  });

  group('the DNS codec', () {
    test('rejects a label that is empty or too long', () {
      expect(() => encodeDnsName(['']), throwsFormatException);
      expect(() => encodeDnsName(['x' * 64]), throwsFormatException);
    });

    test('follows name compression pointers, and refuses a pointer loop', () {
      final packet = Uint8List.fromList([
        0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, // header, two questions
        3, 0x61, 0x62, 0x63, 0, 0, 1, 0, 1, // "abc" A IN
        0xC0, 12, 0, 1, 0, 1, // pointer to the first name
      ]);
      final query = parseDnsQuery(packet)!;
      expect(query.questions.map((q) => q.name), [
        ['abc'],
        ['abc'],
      ]);

      final loop = Uint8List.fromList([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 1, 0, 1]);
      expect(parseDnsQuery(loop), isNull);
    });

    test('a TXT record with no entries is one empty string', () {
      expect(dnsTxt(['x', 'local'], const {}).rdata, [0]);
    });

    test('refuses a TXT entry that does not fit in 255 bytes', () {
      expect(() => dnsTxt(['x'], {'k': Uint8List(255)}), throwsFormatException);
    });
  });
}
