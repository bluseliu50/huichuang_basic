import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';

/// Title bar for the login webview window (second Flutter engine, started
/// from [main] via `runWebViewTitleBarWidget`).
///
/// Replaces the plugin's default left-aligned back/forward/reload row: on
/// macOS the traffic lights (x ≈ 8–74) and the native window title sit in
/// that corner, so the buttons are right-aligned there. Other platforms
/// keep the leading position.
Widget hcWebViewTitleBar(BuildContext context) {
  final state = TitleBarWebViewState.of(context);
  final controller = TitleBarWebViewController.of(context);
  final trailing = Platform.isMacOS;
  final buttons = <Widget>[
    _iconButton(
      onPressed: state.canGoBack ? controller.back : null,
      icon: Icons.arrow_back,
    ),
    _iconButton(
      onPressed: state.canGoForward ? controller.forward : null,
      icon: Icons.arrow_forward,
    ),
    if (state.isLoading)
      _iconButton(onPressed: controller.stop, icon: Icons.close)
    else
      _iconButton(onPressed: controller.reload, icon: Icons.refresh),
  ];
  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      if (trailing) const Spacer(),
      ...buttons,
      if (trailing) const SizedBox(width: 12),
    ],
  );
}

Widget _iconButton({required IconData icon, VoidCallback? onPressed}) {
  return IconButton(
    padding: EdgeInsets.zero,
    splashRadius: 16,
    iconSize: 16,
    onPressed: onPressed,
    icon: Icon(icon),
  );
}
