import 'package:bike_control/utils/keymap/buttons.dart';
import 'package:bike_control/widgets/controller/controller_contour_painter.dart';
import 'package:bike_control/widgets/controller/controller_layout.dart';
import 'package:bike_control/widgets/ui/bk_motion.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

typedef ControllerButtonBuilder = Widget Function(ControllerButton button);

class ControllerCanvas extends StatelessWidget {
  final ControllerLayout layout;
  final List<ControllerButton> availableButtons;
  final ControllerButtonBuilder buttonBuilder;
  final double buttonSize;

  /// Tallest the picture may grow, before scaling. Defaults to 200 for a pill
  /// and 250 for everything else; Ride's wider layouts give it more.
  final double? maxHeight;

  /// Pinned to the outline's own top-right corner — not the canvas', which on
  /// a wide card runs far past the controller — and left at full strength
  /// when [dimmed] fades the rest.
  final Widget? cornerBadge;

  /// Fades the outline and its buttons, for a controller whose buttons do not
  /// work yet.
  final bool dimmed;

  const ControllerCanvas({
    super.key,
    required this.layout,
    required this.availableButtons,
    required this.buttonBuilder,
    this.buttonSize = 56,
    this.maxHeight,
    this.cornerBadge,
    this.dimmed = false,
  });

  /// When a device sets `allowMultiple: true`, its `availableButtons` are
  /// cloned with a per-device `sourceDeviceId` set, which breaks `==` against
  /// the original `ControllerButton` stored in `layout.positions`. Match on
  /// the `name` field instead — unique within any one device's button set.
  Offset? _positionFor(ControllerButton btn) {
    for (final entry in layout.positions.entries) {
      if (entry.key.name == btn.name) return entry.value;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        width: double.infinity,
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(vertical: layout.padding),
        constraints: BoxConstraints(
          maxHeight: (maxHeight ?? (layout.shape == ContourShape.pill ? 200 : 250)) / Theme.of(context).scaling,
        ),
        child: AspectRatio(
          aspectRatio: layout.aspectRatio,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final h = constraints.maxHeight;
              final picture = Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: layout.svgAsset != null
                          ? Transform.flip(
                              flipX: layout.mirrorX,
                              child: RotatedBox(
                                quarterTurns: ((layout.rotation / 90).round() % 4 + 4) % 4,
                                child: SvgPicture.asset(
                                  layout.svgAsset!,
                                  fit: BoxFit.contain,
                                  // The flip mirrors the alignment too.
                                  alignment: layout.mirrorX
                                      ? Alignment(-layout.svgAlignment.x, layout.svgAlignment.y)
                                      : layout.svgAlignment,
                                  colorFilter: Theme.of(context).brightness == Brightness.dark
                                      ? ColorFilter.mode(cs.primary.withValues(alpha: 1), BlendMode.srcIn)
                                      : null,
                                ),
                              ),
                            )
                          : CustomPaint(
                              painter: ControllerContourPainter(
                                shape: layout.shape,
                                color: cs.border,
                                // Subtle darkening via the muted foreground at low alpha
                                // — visually distinct from the solid `cs.muted` button
                                // fill, so the buttons don't blend into the background.
                                fillColor: cs.mutedForeground.withValues(alpha: 0.08),
                              ),
                            ),
                    ),
                  ),
                  for (final btn in availableButtons)
                    if (_positionFor(btn) case final pos?)
                      Positioned(
                        left: (pos.dx * w) - buttonSize / 2,
                        top: (pos.dy * h) - buttonSize / 2,
                        child: buttonBuilder(btn),
                      ),
                ],
              );
              final badge = cornerBadge;
              if (badge == null && !dimmed) return picture;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: AnimatedOpacity(
                      opacity: dimmed ? 0.45 : 1,
                      duration: BkMotion.of(context),
                      curve: BkMotion.curve,
                      child: picture,
                    ),
                  ),
                  if (badge != null) PositionedDirectional(top: 0, end: 0, child: badge),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
