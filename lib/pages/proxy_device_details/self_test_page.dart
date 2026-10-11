import 'package:bike_control/bluetooth/devices/proxy/proxy_device.dart';
import 'package:bike_control/gen/l10n.dart';
import 'package:bike_control/pages/proxy_device_details/self_test_card.dart';
import 'package:bike_control/pages/settings/overlay_settings_page.dart';
import 'package:bike_control/services/trainer_self_test/self_test_engine.dart';
import 'package:bike_control/utils/i18n_extension.dart';
import 'package:bike_control/widgets/ui/bk_page_column.dart';
import 'package:bike_control/widgets/ui/bk_page_header.dart';
import 'package:bike_control/widgets/ui/type_scale.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Settings → Virtual shifting → "Resistance self-test": the self-test on its
/// own page, like the calibrator next to it. Also where the support intake and
/// the setup guide send a rider (see `openTrainerSelfTest`).
///
/// The page is only a frame: [SelfTestCard] still owns the flow (prechecks,
/// running phases, verdict and its calls to action) and persists the verdict
/// the settings row then shows. It sits under a stable key, so nothing that
/// rebuilds the page can restart a run; leaving the page stops it.
class SelfTestPage extends StatelessWidget {
  const SelfTestPage({super.key, required this.device, this.engineFactory});

  final ProxyDevice device;

  /// Test seam, passed on to [SelfTestCard.engineFactory].
  final SelfTestEngine Function()? engineFactory;

  /// The verdict's "Show gear overlay setup": the overlay's own page.
  Future<void> _openOverlaySettings(BuildContext context) async {
    final definition = device.fitnessBike;
    if (definition == null) return;
    await context.push(OverlaySettingsPage(device: device, definition: definition));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    // The card draws nothing without a virtual-shifting definition to test;
    // a reconnect can briefly take it away, so say why the page is empty.
    final noTrainer = engineFactory == null && device.fitnessBike == null;
    return Scaffold(
      headers: [BkPageHeader(title: l10n.selfTestTitle)],
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: BkPageColumn(
          child: noTrainer
              ? Text(l10n.selfTestPrecheckDisconnected, style: context.typography.small.copyWith(color: cs.mutedForeground))
              : SelfTestCard(
                  key: const ValueKey('self-test'),
                  device: device,
                  framed: false,
                  engineFactory: engineFactory,
                  onShowOverlaySettings: () => _openOverlaySettings(context),
                ),
        ),
      ),
    );
  }
}
