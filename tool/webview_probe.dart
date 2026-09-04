// ignore_for_file: avoid_print
// Standalone entrypoint reproducing the login-webview crash reported on
// Linux release builds: open the portal, let the injected script click
// 登录, and watch the navigation to auth.smartedu.cn.
//
//   fvm flutter run -t tool/webview_probe.dart -d linux
//
// Dummy credentials: they are only used on the auth page; the portal
// branch auto-clicks 登录 on its own.
import 'package:flutter/widgets.dart';

import 'package:huichuang_basic/src/auth/login_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox());
  final service = DesktopLoginService();
  final result = await service.login(
    account: '13800000000',
    password: 'probe-dummy',
    onStatus: (m) => print('HC_PROBE status: $m'),
  );
  print('HC_PROBE result: $result');
}
