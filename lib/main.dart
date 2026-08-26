import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:window_manager/window_manager.dart';

import 'src/api/catalog.dart';
import 'src/api/models.dart';
import 'src/api/client.dart';
import 'src/auth/auth_controller.dart';
import 'src/auth/biometric.dart';
import 'src/auth/login_service.dart';
import 'src/auth/token_store.dart';
import 'src/stream/proxy.dart';
import 'src/store/app_state.dart';
import 'src/ui/app_shell.dart';
import 'src/ui/webview_title_bar.dart';

Future<void> main(List<String> args) async {
  // desktop_webview_window on Linux draws the webview title bar in a second
  // Flutter engine whose entrypoint arguments start with 'web_view_title_bar'.
  // That engine has NO plugins registered — without this guard it boots the
  // whole app a second time (MissingPluginException storms, a second proxy,
  // broken method channels) and wrecks the login webview flow.
  if (runWebViewTitleBarWidget(args, builder: hcWebViewTitleBar)) return;

  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final settings = await AppSettings.load();
  final store = TokenStore(FlutterSecureKV());
  // E2E/dev hook: seed the token bundle from env (never committed).
  final tokenJson = Platform.environment['HC_E2E_TOKEN'];
  if (tokenJson != null && tokenJson.isNotEmpty) {
    try {
      final t = TokenBundle.fromUcJson(
          jsonDecode(tokenJson) as Map<String, dynamic>);
      await store.saveToken(t);
      debugPrint('E2E token seeded, expires ${DateTime.fromMillisecondsSinceEpoch(t.expiresAt)}');
    } catch (e) {
      debugPrint('HC_E2E_TOKEN parse failed: $e');
    }
  }
  final auth = AuthController(
    store: store,
    settings: settings,
    biometrics: SystemBiometricGate(),
    loginPerformer: (account, password) async {
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        final r = await DesktopLoginService()
            .login(account: account, password: password);
        return LoginOutcome(r.token, r.failure);
      }
      // Mobile path is widget-based; wired in LoginCard via MobileLoginSheet.
      return const LoginOutcome(null, null);
    },
  );
  final proxy = StreamProxy(
    tokenProvider: () => auth.token?.accessToken,
    onLoginCallback: (raw) async {
      try {
        final t = TokenBundle.fromLocalStorage(raw);
        await auth.acceptExternalToken(t);
      } catch (_) {}
    },
  );
  await proxy.start();
  debugPrint('STREAM_PROXY started on 127.0.0.1:${proxy.port}');

  auth.init(); // silent; never blocks startup

  // Never let window setup abort startup: without it the app renders but the
  // process dies before runApp on hosts where the channel misbehaves.
  try {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      await windowManager.ensureInitialized();
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          title: '惠窗中小学端',
          minimumSize: Size(960, 640),
          size: Size(1366, 900),
        ),
        () async {
          await windowManager.show();
        },
      );
    }
  } catch (e) {
    debugPrint('window_manager unavailable, using platform defaults: $e');
  }
  final client = SmarteduClient();
  final supportDir = await getApplicationSupportDirectory();
  final app = AppController(
    catalog: CatalogService(
      cacheDir: Directory('${supportDir.path}/catalog'),
      client: client,
    ),
    client: client,
  );

  // E2E hook: HC_E2E_RESID=<resId> auto-opens that lesson's player.
  final e2eResId = Platform.environment['HC_E2E_RESID'];

  app.proxy = proxy;

  runApp(HuichuangApp(
    proxy: proxy,
    auth: auth,
    appController: app,
    client: client,
    e2eResId: e2eResId,
  ));
}
class HuichuangApp extends StatelessWidget {
  const HuichuangApp({
    super.key,
    required this.proxy,
    required this.auth,
    required this.appController,
    required this.client,
    this.e2eResId,
  });

  final StreamProxy proxy;
  final AuthController auth;
  final AppController appController;
  final SmarteduClient client;
  final String? e2eResId;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<StreamProxy>.value(value: proxy),
        Provider<SmarteduClient>.value(value: client),
        ChangeNotifierProvider<AuthController>.value(value: auth),
        ChangeNotifierProvider<AppController>.value(value: appController),
      ],
      child: MaterialApp(
        onGenerateTitle: (context) => '惠窗中小学端',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: AppShell(e2eResId: e2eResId),
      ),
    );
  }

  ThemeData _theme(Brightness brightness) {
    const accent = Color(0xFF2E5AAC);
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          brightness == Brightness.light ? const Color(0xFFFAFAF8) : null,
      appBarTheme: AppBarTheme(
        backgroundColor: brightness == Brightness.light
            ? const Color(0xFFFAFAF8)
            : scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: brightness == Brightness.light
            ? const Color(0xFFFAFAF8)
            : scheme.surface,
        labelType: NavigationRailLabelType.all,
        minWidth: 76,
        useIndicator: true,
      ),
      splashFactory: InkSparkle.splashFactory,
    );
  }
}
