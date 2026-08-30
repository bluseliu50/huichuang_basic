import 'package:flutter/widgets.dart';

/// Shared adaptive-width rules (issue #3: 移动端动态宽度适配).
///
/// Mobile window widths are dynamic — rotation, split-screen, foldables —
/// so a single desktop-tuned threshold misclassifies everything in between.
/// Layouts follow the Material 3 window-size classes instead:
///
///   compact  < 600      phone portrait — single column, bottom nav
///   medium   ≥ 600      fold inner portrait (~791dp), tablet portrait,
///                       desktop windows — list-detail two-pane, nav rail
///   expanded ≥ 840      media layouts go side-by-side
///
/// A landscape window is always two-pane regardless of width: width is
/// plentiful there and height is the scarce axis.
abstract final class HcLayout {
  /// Whether a page should use its wide (two-pane) layout.
  ///
  /// [minWidth] is the portrait-window threshold; defaults to the M3
  /// medium breakpoint (600). Landscape windows are always wide.
  static bool twoPane(BuildContext context, {double minWidth = 600}) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= minWidth || size.width > size.height;
  }

  /// Whether the navigation rail shows labels (desktop-class widths).
  static bool extendedRail(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 1280;
}
