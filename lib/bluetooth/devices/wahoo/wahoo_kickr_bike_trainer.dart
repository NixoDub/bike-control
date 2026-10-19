import 'package:bike_control/bluetooth/devices/smart_bike/smart_bike_trainer.dart';
import 'package:bike_control/bluetooth/devices/wahoo/wahoo_kickr_bike_shift.dart';

/// The smart-trainer half of a KICKR BIKE — see [SmartBikeTrainer] for how
/// the role rides on [WahooKickrBikeShift]'s connection. Its own type only so
/// the KICKR BIKE's trainer stays recognisable as such.
class WahooKickrBikeTrainer extends SmartBikeTrainer {
  WahooKickrBikeTrainer(super.scanResult, {required WahooKickrBikeShift super.host, required super.discovered});
}
