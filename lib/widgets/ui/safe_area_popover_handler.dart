import 'package:shadcn_flutter/shadcn_flutter.dart';

/// shadcn's popover handler, kept inside the safe area.
///
/// shadcn lays a popover (a Select's list, a ⋮ menu) out against the whole
/// screen and only keeps a small margin from its edges, so on a phone a tall
/// list slides under the status bar or the gesture bar. This adds the system
/// insets of the app's root to that margin and caps the popover at the space
/// left between them. On desktop the insets are zero, so nothing changes.
class SafeAreaPopoverHandler extends OverlayHandler {
  const SafeAreaPopoverHandler({this.inner = OverlayHandler.popover});

  /// The handler that actually shows the popover.
  final OverlayHandler inner;

  /// The system insets a popover keeps clear of: the status and navigation
  /// bars, display cutouts and an open keyboard, as the app's root sees them
  /// (pages below often remove them from their own MediaQuery).
  static EdgeInsets insetsFor(BuildContext context, {bool rootOverlay = true}) {
    final root = Overlay.maybeOf(context, rootOverlay: rootOverlay)?.context ?? context;
    final media = MediaQuery.maybeOf(root);
    if (media == null) return EdgeInsets.zero;
    final padding = media.padding;
    return EdgeInsets.fromLTRB(
      padding.left,
      padding.top,
      padding.right,
      padding.bottom > media.viewInsets.bottom ? padding.bottom : media.viewInsets.bottom,
    );
  }

  @override
  OverlayCompleter<T?> show<T>({
    required BuildContext context,
    required AlignmentGeometry alignment,
    required WidgetBuilder builder,
    Offset? position,
    AlignmentGeometry? anchorAlignment,
    PopoverConstraint widthConstraint = PopoverConstraint.flexible,
    PopoverConstraint heightConstraint = PopoverConstraint.flexible,
    Key? key,
    bool rootOverlay = true,
    bool modal = true,
    bool barrierDismissable = true,
    Clip clipBehavior = Clip.none,
    Object? regionGroupId,
    Offset? offset,
    AlignmentGeometry? transitionAlignment,
    EdgeInsetsGeometry? margin,
    bool follow = true,
    bool consumeOutsideTaps = true,
    ValueChanged<PopoverOverlayWidgetState>? onTickFollow,
    bool allowInvertHorizontal = true,
    bool allowInvertVertical = true,
    bool dismissBackdropFocus = true,
    Duration? showDuration,
    Duration? dismissDuration,
    OverlayBarrier? overlayBarrier,
    LayerLink? layerLink,
  }) {
    final insets = insetsFor(context, rootOverlay: rootOverlay);
    final theme = Theme.of(context);
    // shadcn's own default margin when none is given.
    final base = margin?.resolve(Directionality.of(context)) ?? EdgeInsets.all(theme.density.baseGap * theme.scaling);
    final safeMargin = base + insets;
    final root = Overlay.maybeOf(context, rootOverlay: rootOverlay)?.context ?? context;
    final screen = MediaQuery.maybeSizeOf(root);
    WidgetBuilder safeBuilder = builder;
    if (screen != null && insets != EdgeInsets.zero) {
      // The popover is laid out against the whole screen; without a cap a
      // list taller than the room between the bars still runs under them.
      final maxHeight = (screen.height - safeMargin.vertical).clamp(0.0, double.infinity);
      final maxWidth = (screen.width - safeMargin.horizontal).clamp(0.0, double.infinity);
      safeBuilder = (context) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: maxWidth),
        child: builder(context),
      );
    }
    return inner.show<T>(
      context: context,
      alignment: alignment,
      builder: safeBuilder,
      position: position,
      anchorAlignment: anchorAlignment,
      widthConstraint: widthConstraint,
      heightConstraint: heightConstraint,
      key: key,
      rootOverlay: rootOverlay,
      modal: modal,
      barrierDismissable: barrierDismissable,
      clipBehavior: clipBehavior,
      regionGroupId: regionGroupId,
      offset: offset,
      transitionAlignment: transitionAlignment,
      margin: safeMargin,
      follow: follow,
      consumeOutsideTaps: consumeOutsideTaps,
      onTickFollow: onTickFollow,
      allowInvertHorizontal: allowInvertHorizontal,
      allowInvertVertical: allowInvertVertical,
      dismissBackdropFocus: dismissBackdropFocus,
      showDuration: showDuration,
      dismissDuration: dismissDuration,
      overlayBarrier: overlayBarrier,
      layerLink: layerLink,
    );
  }
}
