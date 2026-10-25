import 'dart:convert';
import 'dart:typed_data';

/// The slice of DNS (RFC 1035) multicast DNS needs: reading the questions of a
/// query and writing a response made of A, PTR, TXT and SRV records.
///
/// Names are lists of labels rather than dotted strings, because a DNS-SD
/// instance name is one label that may itself contain dots.
const int dnsTypeA = 1;
const int dnsTypePtr = 12;
const int dnsTypeTxt = 16;
const int dnsTypeSrv = 33;
const int dnsTypeAny = 255;
const int dnsClassIn = 1;

typedef DnsName = List<String>;

class DnsQuestion {
  const DnsQuestion({required this.name, required this.type, required this.unicastResponse});

  final DnsName name;
  final int type;

  /// The QU bit: the asker would take a unicast answer (RFC 6762 §5.4).
  final bool unicastResponse;

  @override
  String toString() => '${dnsTypeName(type)} ${name.join('.')}';
}

class DnsRecord {
  const DnsRecord({
    required this.name,
    required this.type,
    required this.ttl,
    required this.rdata,
    this.cacheFlush = false,
  });

  final DnsName name;
  final int type;
  final int ttl;
  final bool cacheFlush;

  /// The record data, already in wire format (names inside it uncompressed).
  final Uint8List rdata;

  DnsRecord withTtl(int ttl) => DnsRecord(name: name, type: type, ttl: ttl, rdata: rdata, cacheFlush: cacheFlush);

  /// Two records answer the same question when name and type agree.
  String get key => '${name.map((l) => l.toLowerCase()).join('\u0000')}|$type';
}

class DnsQuery {
  const DnsQuery({required this.id, required this.isResponse, required this.questions});

  final int id;
  final bool isResponse;
  final List<DnsQuestion> questions;
}

String dnsTypeName(int type) => switch (type) {
  dnsTypeA => 'A',
  dnsTypePtr => 'PTR',
  dnsTypeTxt => 'TXT',
  dnsTypeSrv => 'SRV',
  dnsTypeAny => 'ANY',
  28 => 'AAAA',
  _ => 'TYPE$type',
};

bool dnsNamesEqual(DnsName a, DnsName b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].toLowerCase() != b[i].toLowerCase()) return false;
  }
  return true;
}

/// Reads the header and the question section of [packet]; the answer sections
/// are not needed. Returns null for a packet that is not valid DNS.
DnsQuery? parseDnsQuery(Uint8List packet) {
  try {
    if (packet.length < 12) return null;
    final view = ByteData.sublistView(packet);
    final id = view.getUint16(0);
    final flags = view.getUint16(2);
    final questionCount = view.getUint16(4);
    var offset = 12;
    final questions = <DnsQuestion>[];
    for (var i = 0; i < questionCount; i++) {
      final name = _readName(packet, offset);
      offset = name.next;
      if (offset + 4 > packet.length) return null;
      final type = view.getUint16(offset);
      final klass = view.getUint16(offset + 2);
      offset += 4;
      questions.add(DnsQuestion(name: name.labels, type: type, unicastResponse: klass & 0x8000 != 0));
    }
    return DnsQuery(id: id, isResponse: flags & 0x8000 != 0, questions: questions);
  } on RangeError {
    return null;
  } on FormatException {
    return null;
  }
}

({DnsName labels, int next}) _readName(Uint8List packet, int start) {
  final labels = <String>[];
  var offset = start;
  int? next;
  var jumps = 0;
  while (true) {
    if (offset >= packet.length) throw const FormatException('name runs off the packet');
    final length = packet[offset];
    if (length == 0) {
      offset += 1;
      break;
    }
    if (length & 0xC0 == 0xC0) {
      if (offset + 1 >= packet.length) throw const FormatException('truncated pointer');
      next ??= offset + 2;
      offset = ((length & 0x3F) << 8) | packet[offset + 1];
      if (++jumps > 16) throw const FormatException('pointer loop');
      continue;
    }
    if (length & 0xC0 != 0) throw const FormatException('unsupported label type');
    if (offset + 1 + length > packet.length) throw const FormatException('label runs off the packet');
    labels.add(utf8.decode(packet.sublist(offset + 1, offset + 1 + length), allowMalformed: true));
    offset += 1 + length;
  }
  return (labels: labels, next: next ?? offset);
}

Uint8List encodeDnsName(DnsName name) {
  final out = BytesBuilder(copy: false);
  for (final label in name) {
    final bytes = utf8.encode(label);
    if (bytes.isEmpty || bytes.length > 63) throw FormatException('Not a valid DNS label', label);
    out.addByte(bytes.length);
    out.add(bytes);
  }
  out.addByte(0);
  return out.toBytes();
}

/// An mDNS response (QR and AA set). A multicast response carries id 0; a
/// reply to a legacy unicast resolver echoes the query's [id] and [questions].
Uint8List buildDnsResponse({
  required List<DnsRecord> answers,
  List<DnsRecord> additional = const [],
  int id = 0,
  List<DnsQuestion> questions = const [],
}) {
  final out = BytesBuilder(copy: false);
  void u16(int v) => out.add([(v >> 8) & 0xff, v & 0xff]);
  void u32(int v) => out.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
  void record(DnsRecord r) {
    out.add(encodeDnsName(r.name));
    u16(r.type);
    u16(dnsClassIn | (r.cacheFlush ? 0x8000 : 0));
    u32(r.ttl);
    u16(r.rdata.length);
    out.add(r.rdata);
  }

  u16(id);
  u16(0x8400);
  u16(questions.length);
  u16(answers.length);
  u16(0);
  u16(additional.length);
  for (final q in questions) {
    out.add(encodeDnsName(q.name));
    u16(q.type);
    u16(dnsClassIn);
  }
  answers.forEach(record);
  additional.forEach(record);
  return out.toBytes();
}

DnsRecord dnsPtr(DnsName name, DnsName target, {int ttl = 4500}) =>
    DnsRecord(name: name, type: dnsTypePtr, ttl: ttl, rdata: encodeDnsName(target));

DnsRecord dnsSrv(DnsName name, DnsName target, int port, {int ttl = 120}) {
  final rdata = BytesBuilder(copy: false)
    ..add([0, 0, 0, 0, (port >> 8) & 0xff, port & 0xff])
    ..add(encodeDnsName(target));
  return DnsRecord(name: name, type: dnsTypeSrv, ttl: ttl, rdata: rdata.toBytes(), cacheFlush: true);
}

DnsRecord dnsA(DnsName name, List<int> ipv4, {int ttl = 120}) {
  if (ipv4.length != 4) throw ArgumentError.value(ipv4.length, 'ipv4.length', 'An IPv4 address is 4 bytes');
  return DnsRecord(name: name, type: dnsTypeA, ttl: ttl, rdata: Uint8List.fromList(ipv4), cacheFlush: true);
}

/// A TXT record: each entry is a length-prefixed `key=value` string. An empty
/// map is a single zero-length string, as RFC 6763 §6.1 requires.
DnsRecord dnsTxt(DnsName name, Map<String, Uint8List> txt, {int ttl = 4500}) {
  final rdata = BytesBuilder(copy: false);
  for (final entry in txt.entries) {
    final key = ascii.encode(entry.key);
    final length = key.length + 1 + entry.value.length;
    if (length > 255) throw FormatException('TXT entry "${entry.key}" is $length bytes; at most 255 fit');
    rdata
      ..addByte(length)
      ..add(key)
      ..addByte(0x3d)
      ..add(entry.value);
  }
  if (txt.isEmpty) rdata.addByte(0);
  return DnsRecord(name: name, type: dnsTypeTxt, ttl: ttl, rdata: rdata.toBytes(), cacheFlush: true);
}

/// A whole DNS message with its record sections decoded, for checking what the
/// encoder wrote (and for reading other devices' announcements).
class DnsMessage {
  const DnsMessage({
    required this.id,
    required this.flags,
    required this.questions,
    required this.answers,
    required this.additional,
  });

  final int id;
  final int flags;
  final List<DnsQuestion> questions;
  final List<DnsRecord> answers;
  final List<DnsRecord> additional;
}

DnsMessage? parseDnsMessage(Uint8List packet) {
  try {
    final query = parseDnsQuery(packet);
    if (query == null) return null;
    final view = ByteData.sublistView(packet);
    final answerCount = view.getUint16(6);
    final authorityCount = view.getUint16(8);
    final additionalCount = view.getUint16(10);
    var offset = 12;
    for (var i = 0; i < query.questions.length; i++) {
      offset = _readName(packet, offset).next + 4;
    }
    List<DnsRecord> records(int count) {
      final out = <DnsRecord>[];
      for (var i = 0; i < count; i++) {
        final name = _readName(packet, offset);
        offset = name.next;
        final type = view.getUint16(offset);
        final klass = view.getUint16(offset + 2);
        final ttl = view.getUint32(offset + 4);
        final length = view.getUint16(offset + 8);
        offset += 10;
        out.add(
          DnsRecord(
            name: name.labels,
            type: type,
            ttl: ttl,
            cacheFlush: klass & 0x8000 != 0,
            rdata: Uint8List.fromList(packet.sublist(offset, offset + length)),
          ),
        );
        offset += length;
      }
      return out;
    }

    final answers = records(answerCount);
    records(authorityCount);
    return DnsMessage(
      id: query.id,
      flags: view.getUint16(2),
      questions: query.questions,
      answers: answers,
      additional: records(additionalCount),
    );
  } on RangeError {
    return null;
  } on FormatException {
    return null;
  }
}

/// The target name inside a PTR record's data.
DnsName dnsPtrTarget(DnsRecord record) => _readName(record.rdata, 0).labels;

/// Port and target of an SRV record.
({int port, DnsName target}) dnsSrvData(DnsRecord record) {
  final view = ByteData.sublistView(record.rdata);
  return (port: view.getUint16(4), target: _readName(record.rdata, 6).labels);
}

/// The `key=value` entries of a TXT record.
Map<String, String> dnsTxtData(DnsRecord record) {
  final out = <String, String>{};
  var offset = 0;
  while (offset < record.rdata.length) {
    final length = record.rdata[offset];
    if (length == 0) break;
    final entry = utf8.decode(record.rdata.sublist(offset + 1, offset + 1 + length), allowMalformed: true);
    final eq = entry.indexOf('=');
    out[eq < 0 ? entry : entry.substring(0, eq)] = eq < 0 ? '' : entry.substring(eq + 1);
    offset += 1 + length;
  }
  return out;
}
