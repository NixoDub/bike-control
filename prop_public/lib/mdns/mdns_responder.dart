//INFO: This is a stub - contact me if you need the full implementation.
//
// The full implementation is an in-process mDNS responder. This stub keeps
// only the query-log entry the app renders in its diagnostics.

/// One mDNS query this responder saw, with repeats folded together.
class MdnsQueryLogEntry {
  /// When this query was last seen. Updated on every repeat.
  DateTime at;

  /// Querier address, e.g. '192.168.178.50'.
  final String source;

  final int sourcePort;

  /// Whether the query asked for a unicast reply (the QU bit, RFC 6762 §5.4).
  final bool wantsUnicast;

  /// Human-readable questions, e.g. 'PTR _wahoo-fitness-tnp._tcp.local'.
  final List<String> questions;

  bool answeredUnicast;
  bool answeredMulticast;

  /// Whether this query was most likely our own app browsing, so diagnostics
  /// do not count it as a trainer app asking for us.
  final bool duringOwnBrowse;

  /// How the responder answered, for diagnostics: `multicast`, `unicast` or
  /// `no match`.
  String reply;

  /// How many times this exact query was seen in a row.
  int count;

  MdnsQueryLogEntry({
    required this.at,
    required this.source,
    required this.sourcePort,
    required this.wantsUnicast,
    required this.questions,
    required this.answeredUnicast,
    required this.answeredMulticast,
    this.duringOwnBrowse = false,
    this.reply = '',
    this.count = 1,
  });

  @override
  String toString() => '$source:$sourcePort';
}

/// Marks the windows during which BikeControl itself browses mDNS, so the
/// queries it provokes are not mistaken for a trainer app's. Stubbed: only
/// the nesting counter is kept.
class OwnMdnsBrowsing {
  OwnMdnsBrowsing._();

  static int _active = 0;

  static bool get isBrowsing => _active > 0;

  static void begin() => _active++;

  static void end() {
    if (_active > 0) _active--;
  }
}
