/// Bluetooth SIG Cycling Speed and Cadence Measurement (0x2A5B): parsing,
/// encoding, and the speed and cadence two consecutive samples give.
library;

/// A parsed Cycling Speed and Cadence (CSC) Measurement notification.
class CscMeasurement {
  final int? cumWheelRevs;
  final int? lastWheelEventTime1024s;
  final int? cumCrankRevs;
  final int? lastCrankEventTime1024s;

  const CscMeasurement({
    this.cumWheelRevs,
    this.lastWheelEventTime1024s,
    this.cumCrankRevs,
    this.lastCrankEventTime1024s,
  });

  /// Flags (8 bit): bit 0 wheel revolution data (uint32 revs, uint16 time),
  /// bit 1 crank revolution data (uint16 revs, uint16 time). Null for a frame
  /// too short for what its flags promise.
  static CscMeasurement? parse(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final flags = bytes[0];
    var offset = 1;
    int? wheelRevs, wheelTime, crankRevs, crankTime;
    if (flags & 0x01 != 0) {
      if (bytes.length < offset + 6) return null;
      wheelRevs = _u32(bytes, offset);
      wheelTime = _u16(bytes, offset + 4);
      offset += 6;
    }
    if (flags & 0x02 != 0) {
      if (bytes.length < offset + 4) return null;
      crankRevs = _u16(bytes, offset);
      crankTime = _u16(bytes, offset + 2);
    }
    return CscMeasurement(
      cumWheelRevs: wheelRevs,
      lastWheelEventTime1024s: wheelTime,
      cumCrankRevs: crankRevs,
      lastCrankEventTime1024s: crankTime,
    );
  }
}

int _u16(List<int> b, int o) => b[o] | (b[o + 1] << 8);

int _u32(List<int> b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

/// Cadence in RPM derived from two consecutive CSC samples, or null when the
/// pair has no crank data or no time between its events (a repeated frame, not
/// a stopped crank: nothing can be divided by it).
int? cscCadenceRpm(CscMeasurement prev, CscMeasurement cur) {
  final prevRevs = prev.cumCrankRevs, curRevs = cur.cumCrankRevs;
  final prevTime = prev.lastCrankEventTime1024s, curTime = cur.lastCrankEventTime1024s;
  if (prevRevs == null || curRevs == null || prevTime == null || curTime == null) return null;
  final dTime = (curTime - prevTime) & 0xFFFF;
  if (dTime == 0) return null;
  final dRevs = (curRevs - prevRevs) & 0xFFFF;
  return (dRevs * 1024 * 60 / dTime).round();
}

/// Bike speed in m/s derived from two consecutive CSC samples.
double? cscSpeedMps(
  CscMeasurement prev,
  CscMeasurement cur, {
  required double wheelCircumferenceMeters,
}) {
  final prevRevs = prev.cumWheelRevs, curRevs = cur.cumWheelRevs;
  final prevTime = prev.lastWheelEventTime1024s, curTime = cur.lastWheelEventTime1024s;
  if (prevRevs == null || curRevs == null || prevTime == null || curTime == null) return null;
  final dTime = (curTime - prevTime) & 0xFFFF;
  if (dTime == 0) return null;
  final dRevs = (curRevs - prevRevs) & 0xFFFFFFFF;
  return dRevs * wheelCircumferenceMeters / (dTime / 1024);
}

/// The one quantum [advanceCrankCounter] steps by: a minute, in 1/1024 s.
const int _crankQuantum1024 = 60 * 1024;

/// Advances a cumulative crank-revolution counter and its paired event-time
/// clock by [rpm] revolutions over one fixed quantum.
///
/// The quantum is a whole minute, so [rpm] is exactly the number of
/// revolutions it holds: two frames built from consecutive calls decode back
/// to [rpm] through [cscCadenceRpm] (or the power-meter twin), whatever the
/// rate. A constant frame sent twice would instead repeat the same event and
/// encode no cadence at all. Both counters wrap at 16 bits, as on the wire.
({int crankRevs, int eventTime1024}) advanceCrankCounter({
  required int crankRevs,
  required int eventTime1024,
  required int rpm,
}) => (
  crankRevs: (crankRevs + rpm) & 0xFFFF,
  eventTime1024: (eventTime1024 + _crankQuantum1024) & 0xFFFF,
);

/// Encodes a crank-only CSC Measurement frame.
List<int> buildCscMeasurement(int crankRevs, int eventTime1024) => [
  0x02,
  crankRevs & 0xFF,
  (crankRevs >> 8) & 0xFF,
  eventTime1024 & 0xFF,
  (eventTime1024 >> 8) & 0xFF,
];
