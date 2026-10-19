import 'package:bike_control/utils/core.dart';
import 'package:bike_control/utils/i18n_extension.dart';
import 'package:bike_control/widgets/ignored_devices_dialog.dart';
import 'package:bike_control/widgets/ui/colors.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// "Found ignored devices nearby · Manage" — shown while the scan sees a
/// device the rider once put on the ignore list.
///
/// A controller on that list is never added or connected, so to the rider it
/// simply "doesn't show up" and every pairing tip fails. This line says why,
/// and Manage opens the list so it can come back. Renders nothing otherwise.
class IgnoredDevicesNearbyHint extends StatelessWidget {
  const IgnoredDevicesNearbyHint({super.key, this.alignment = MainAxisAlignment.start, this.padding = EdgeInsets.zero});

  final MainAxisAlignment alignment;

  /// Space around the line, applied only while it shows — so a screen with
  /// nothing ignored nearby keeps its layout.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: core.connection.ignoredDevicesNearby,
      builder: (context, nearby, _) {
        if (nearby.isEmpty) return const SizedBox.shrink();
        final l = context.i18n;
        final muted = Theme.of(context).colorScheme.mutedForeground;
        final row = Row(
          key: const ValueKey('ignored-devices-nearby-hint'),
          mainAxisAlignment: alignment,
          spacing: 6,
          children: [
            Icon(LucideIcons.eyeOff, size: 14, color: muted),
            Flexible(child: Text(l.ignoredDevicesNearby).xSmall.muted),
            Button.ghost(
              key: const ValueKey('ignored-devices-nearby-manage'),
              style: const ButtonStyle.ghost(density: ButtonDensity.compact),
              onPressed: () => showDialog(context: context, builder: (_) => const IgnoredDevicesDialog()),
              child: Text(l.manageAction, style: TextStyle(color: bkAccentText(context))).xSmall.semiBold,
            ),
          ],
        );
        return padding == EdgeInsets.zero ? row : Padding(padding: padding, child: row);
      },
    );
  }
}
