/// Bluetooth SIG Cycling Power Measurement (0x2A63): parsing, encoding and the
/// cadence two consecutive samples give.
library;

/// A parsed Cycling Power Measurement notification.
class CpsMeasurement {
  final int powerWatts;
  final int? cumCrankRevs;
  final int? lastCrankEventTime1024s;
  final int? cumWheelRevs;
  final int? lastWheelEventTime2048s;

  const CpsMeasurement({
    required this.powerWatts,
    this.cumCrankRevs,
    this.lastCrankEventTime1024s,
    this.cumWheelRevs,
    this.lastWheelEventTime2048s,
  });

  /// Flags (16 bit) then the instantaneous power (sint16, watts), followed by
  /// the optional fields in a fixed order: pedal power balance (bit 0, uint8),
  /// accumulated torque (bit 2, uint16), wheel revolution data (bit 4, uint32
  /// revs and uint16 time in 1/2048 s), crank revolution data (bit 5, uint16
  /// revs and uint16 time in 1/1024 s). Null for a frame too short for what
  /// its flags promise.
  static CpsMeasurement? parse(List<int> bytes) {
    if (bytes.length < 4) return null;
    final flags = bytes[0] | (bytes[1] << 8);
    var power = bytes[2] | (bytes[3] << 8);
    if (power >= 0x8000) power -= 0x10000;
    var offset = 4;
    if (flags & 0x0001 != 0) offset += 1;
    if (flags & 0x0004 != 0) offset += 2;
    int? wheelRevs, wheelTime, crankRevs, crankTime;
    if (flags & 0x0010 != 0) {
      if (bytes.length < offset + 6) return null;
      wheelRevs = bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
      wheelTime = bytes[offset + 4] | (bytes[offset + 5] << 8);
      offset += 6;
    }
    if (flags & 0x0020 != 0) {
      if (bytes.length < offset + 4) return null;
      crankRevs = bytes[offset] | (bytes[offset + 1] << 8);
      crankTime = bytes[offset + 2] | (bytes[offset + 3] << 8);
    }
    if (offset > bytes.length) return null;
    return CpsMeasurement(
      powerWatts: power,
      cumCrankRevs: crankRevs,
      lastCrankEventTime1024s: crankTime,
      cumWheelRevs: wheelRevs,
      lastWheelEventTime2048s: wheelTime,
    );
  }
}

/// Cadence in RPM derived from two consecutive Cycling Power samples, or null
/// when the pair has no crank data or no time between its events.
int? cpsCadenceRpm(CpsMeasurement prev, CpsMeasurement cur) {
  final prevRevs = prev.cumCrankRevs, curRevs = cur.cumCrankRevs;
  final prevTime = prev.lastCrankEventTime1024s, curTime = cur.lastCrankEventTime1024s;
  if (prevRevs == null || curRevs == null || prevTime == null || curTime == null) return null;
  final dTime = (curTime - prevTime) & 0xFFFF;
  if (dTime == 0) return null;
  final dRevs = (curRevs - prevRevs) & 0xFFFF;
  return (dRevs * 1024 * 60 / dTime).round();
}

/// Encodes a Cycling Power Measurement frame: the power, plus crank revolution
/// data when [crankRevs] is given.
List<int> buildCyclingPowerMeasurement(
  int watts, {
  int? crankRevs,
  int? eventTime1024,
}) {
  final withCrank = crankRevs != null;
  final power = watts & 0xFFFF;
  return [
    withCrank ? 0x20 : 0x00,
    0x00,
    power & 0xFF,
    (power >> 8) & 0xFF,
    if (withCrank) ...[
      crankRevs & 0xFF,
      (crankRevs >> 8) & 0xFF,
      (eventTime1024 ?? 0) & 0xFF,
      ((eventTime1024 ?? 0) >> 8) & 0xFF,
    ],
  ];
}
