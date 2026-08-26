import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'package:huichuang_basic/src/api/models.dart';
import 'package:huichuang_basic/src/auth/auth_controller.dart';
import 'package:huichuang_basic/src/auth/biometric.dart';
import 'package:huichuang_basic/src/auth/login_service.dart'
    show LoginOutcome;
import 'package:huichuang_basic/src/auth/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

TokenBundle _token({int? expiresInMs}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return TokenBundle(
    accessToken: 'acc-${expiresInMs ?? 0}',
    refreshToken: 'ref-old',
    userId: 'u1',
    macKey: 'mk',
    expiresAt: now + (expiresInMs ?? 10 * 24 * 3600 * 1000),
  );
}

/// Simulates hosts without a Secret Service: every call throws.
class ThrowingKV implements SecureKeyValue {
  @override
  Future<String?> read(String key) async => throw Exception('no keyring');
  @override
  Future<void> write(String key, String value) async =>
      throw Exception('no keyring');
  @override
  Future<void> delete(String key) async => throw Exception('no keyring');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryKV kv;
  late TokenStore store;
  late AppSettings settings;
  late FakeBiometricGate gate;
  final controllers = <AuthController>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = MemoryKV();
    store = TokenStore(kv);
    settings = await AppSettings.load();
    gate = FakeBiometricGate();
  });

  tearDown(() {
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
  });

  AuthController controller({
    Future<TokenBundle?> Function(TokenBundle)? refresher,
    LoginPerformer? performer,
  }) {
    final c = AuthController(
      store: store,
      settings: settings,
      biometrics: gate,
      loginPerformer: performer,
      refresher: refresher,
    );
    controllers.add(c);
    return c;
  }

  test('startup with no token → loggedOut, no biometric prompt', () async {
    final c = controller();
    await c.init();
    expect(c.status, AuthStatus.loggedOut);
    expect(gate.calls, 0);
  });

  test('startup with fresh token → silent login, no refresh, no biometrics',
      () async {
    await store.saveToken(_token());
    var refreshCalls = 0;
    final c = controller(refresher: (t) async {
      refreshCalls++;
      return null;
    });
    await c.init();
    expect(c.status, AuthStatus.loggedIn);
    expect(refreshCalls, 0, reason: 'fresh token must not be refreshed');
    expect(gate.calls, 0, reason: 'biometrics never gate startup');
  });

  test('startup with near-expiry token refreshes and persists rotation',
      () async {
    await store.saveToken(_token(expiresInMs: 3600 * 1000));
    final fresh = _token(expiresInMs: 7 * 24 * 3600 * 1000);
    final c = controller(
        refresher: (old) async => TokenBundle(
              accessToken: 'acc-new',
              refreshToken: 'ref-new',
              userId: old.userId,
              macKey: old.macKey,
              expiresAt: fresh.expiresAt,
            ));
    await c.init();
    expect(c.status, AuthStatus.loggedIn);
    expect(c.token!.accessToken, 'acc-new');
    final persisted = await store.loadToken();
    expect(persisted!.accessToken, 'acc-new');
  });

  test('ensureValidToken refreshes lazily when the clock moves on', () async {
    var clock = DateTime.now();
    await store.saveToken(_token(expiresInMs: 60 * 3600 * 1000)); // 60h left
    var refreshCalls = 0;
    final c2 = AuthController(
      store: store,
      settings: settings,
      biometrics: gate,
      refresher: (old) async {
        refreshCalls++;
        return _token(expiresInMs: 7 * 24 * 3600 * 1000);
      },
      now: () => clock,
    );
    controllers.add(c2);
    await c2.init();
    expect(c2.status, AuthStatus.loggedIn);
    expect(refreshCalls, 0, reason: '60h remaining is above the threshold');

    // 20h later the token is inside the 48h window.
    clock = clock.add(const Duration(hours: 20));
    final t = await c2.ensureValidToken();
    expect(t, isNotNull);
    expect(refreshCalls, 1);
    expect(c2.token!.accessToken, isNot('acc-216000000'));
  });

  test('unlockPassword gated by biometrics only when enabled', () async {
    await store.savePassword('13800000000', 'secret');
    settings.biometricProtect = true;

    final c = controller();
    gate.shouldPass = false;
    expect(await c.unlockPassword(), isNull);
    expect(gate.calls, 1);

    gate.shouldPass = true;
    expect(await c.unlockPassword(), 'secret');

    settings.biometricProtect = false;
    gate.calls = 0;
    expect(await c.unlockPassword(), 'secret');
    expect(gate.calls, 0, reason: 'no biometric when toggle off');
  });

  test('login persists token and password; logout wipes', () async {
    final given = _token();
    final c = controller(performer: (account, password) async {
      expect(account, '188');
      expect(password, 'pw');
      return LoginOutcome(given, null);
    });
    final ok = await c.login('188', 'pw');
    expect(ok, isTrue);
    expect(c.status, AuthStatus.loggedIn);
    expect(await store.loadPassword(), 'pw');
    expect(c.savedAccount, '188');

    await c.logout(wipeCredentials: true);
    expect(c.status, AuthStatus.loggedOut);
    expect(await store.loadPassword(), isNull);
    expect(await store.loadToken(), isNull);
  });

  test('soft logout keeps credentials for prefill; wipe clears them',
      () async {
    final c = controller(
        performer: (a, p) async => LoginOutcome(_token(), null));
    expect(await c.login('188', 'pw'), isTrue);
    expect(c.savedAccount, '188');

    // 仅退出: token gone, vault credentials + savedAccount survive so the
    // login card can prefill and unlock the password with biometrics.
    await c.logout();
    expect(c.status, AuthStatus.loggedOut);
    expect(c.token, isNull);
    expect(c.savedAccount, '188');
    expect(await store.loadPassword(), 'pw');

    // 删除并退出: everything wiped.
    await c.login('188', 'pw');
    await c.logout(wipeCredentials: true);
    expect(c.savedAccount, isNull);
    expect(await store.loadPassword(), isNull);
  });

  test('failed login surfaces the page-reported failure message', () async {
    final c = controller(
        performer: (a, p) async =>
            const LoginOutcome(null, '账号或密码错误，请重新输入'));
    expect(await c.login('188', 'wrong'), isFalse);
    expect(c.lastLoginFailure, '账号或密码错误，请重新输入');

    // A subsequent success clears the stale failure.
    final c2 =
        controller(performer: (a, p) async => LoginOutcome(_token(), null));
    expect(await c2.login('188', 'pw'), isTrue);
    expect(c2.lastLoginFailure, isNull);
  });

  test('authenticateForLogin gates the login action when protection is on',
      () async {
    final c = controller();

    settings.biometricProtect = false;
    expect(await c.authenticateForLogin(), isTrue);
    expect(gate.calls, 0, reason: 'no prompt when toggle off');

    settings.biometricProtect = true;
    gate.shouldPass = false;
    expect(await c.authenticateForLogin(), isFalse);
    expect(gate.calls, 1);

    gate.shouldPass = true;
    expect(await c.authenticateForLogin(), isTrue);
    expect(gate.calls, 2);
  });

  test('unusable secure storage disables the vault, not the login', () async {
    final broken = TokenStore(ThrowingKV());
    final cacheFile = File(
        '${Directory.systemTemp.createTempSync('hc_auth_test').path}/session.bin');
    final cache = TokenFileCache(cacheFile);
    settings.biometricProtect = true; // also the fresh-install default
    final c = AuthController(
        store: broken,
        settings: settings,
        biometrics: gate,
        tokenCache: cache);
    controllers.add(c);
    await c.init();
    expect(c.status, AuthStatus.loggedOut);
    expect(c.biometricProtect, isFalse, reason: 'protection is inert');
    expect(await c.biometricsAvailable(), isFalse, reason: 'switch hidden');
    expect(await c.authenticateForLogin(), isTrue, reason: 'no prompt');
    expect(gate.calls, 0, reason: 'biometrics never fire without storage');

    // Login works and the SESSION survives a restart via the file cache
    // (token only — the password is never written there).
    final c2 = AuthController(
        store: broken,
        settings: settings,
        biometrics: gate,
        tokenCache: cache,
        loginPerformer: (a, p) async => LoginOutcome(_token(), null));
    controllers.add(c2);
    await c2.init();
    expect(await c2.login('13800000000', 'pw'), isTrue);
    expect(c2.status, AuthStatus.loggedIn);
    expect(c2.token, isNotNull);
    expect(await cacheFile.exists(), isTrue);

    final c3 = AuthController(
        store: broken, settings: settings, biometrics: gate, tokenCache: cache);
    controllers.add(c3);
    await c3.init();
    expect(c3.status, AuthStatus.loggedIn, reason: 'token restored from cache');
    expect(c3.savedAccount, '13800000000');
    expect(gate.calls, 0, reason: 'still no biometrics at startup');

    await c3.logout();
    expect(await cacheFile.exists(), isFalse, reason: 'logout clears cache');
  });

  test('no biometric provider disables protection but keeps saving', () async {
    // local_auth has no Linux implementation: availability check throws,
    // which isAvailable() turns into false. Secure storage still works.
    final noHardware = FakeBiometricGate(available: false);
    settings.biometricProtect = true; // also the fresh-install default
    final c = AuthController(
        store: store, settings: settings, biometrics: noHardware);
    controllers.add(c);
    await c.init();
    expect(c.biometricProtect, isFalse,
        reason: 'protection inert without a biometric provider');
    expect(await c.biometricsAvailable(), isFalse);
    expect(await c.authenticateForLogin(), isTrue, reason: 'no prompt');
    expect(noHardware.calls, 0);
  });
}
