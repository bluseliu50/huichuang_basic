import 'package:flutter/widgets.dart';

/// Shared adaptive-width rules (issue #3: 移动端动态宽度适配).
///
/// Mobile window widths are dynamic — rotation, split-screen, foldables —
/// so a bare width threshold misclassifies a landscape phone (600–1000
/// logical px wide, very little height) as "narrow portrait". Any
/// landscape window gets the wide layouts: width is plentiful there and
/// height is the scarce axis.
abstract final class HcLayout {
  /// Whether a page should use its wide (two-pane) layout.
  ///
  /// [minWidth] is the portrait-window threshold; landscape windows are
  /// always wide regardless of it.
  static bool twoPane(BuildContext context, {double minWidth = 1000}) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= minWidth || size.width > size.height;
  }

  /// Whether the navigation rail shows labels (desktop-class widths).
  static bool extendedRail(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 1280;
}
