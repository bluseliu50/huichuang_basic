/// App-wide auth state: silent startup, rolling token refresh, 401 retry,
/// biometric-gated credential vault (never at launch).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'biometric.dart';
import 'token_store.dart';

enum AuthStatus { loading, loggedOut, loggedIn, needsRelogin }

/// Performs an interactive webview login. Wired by the app shell
/// (mobile uses a widget route, desktop a webview window).
typedef LoginPerformer = Future<TokenBundle?> Function(
    String account, String password);

class AuthController extends ChangeNotifier {
  AuthController({
    required TokenStore store,
    required AppSettings settings,
    BiometricGate? biometrics,
    SmarteduClient? client,
    LoginPerformer? loginPerformer,
    DateTime Function()? now,
    Future<TokenBundle?> Function(TokenBundle old)? refresher,
  })  : _store = store,
        _settings = settings,
        _biometrics = biometrics ?? SystemBiometricGate(),
        _client = client ?? SmarteduClient(),
        _loginPerformer = loginPerformer,
        _now = now ?? DateTime.now,
        _refresher = refresher ?? _defaultRefresh;

  final TokenStore _store;
  final AppSettings _settings;
  final BiometricGate _biometrics;
  final SmarteduClient _client;
  final LoginPerformer? _loginPerformer;
  final DateTime Function() _now;
  final Future<TokenBundle?> Function(TokenBundle) _refresher;

  static Future<TokenBundle?> _defaultRefresh(TokenBundle old) async {
    try {
      return await SmarteduClient.refreshToken(old.refreshToken);
    } catch (_) {
      return null;
    }
  }

  AuthStatus status = AuthStatus.loading;
  TokenBundle? token;
  UserInfo? user;
  String? savedAccount;

  bool _refreshing = false;
  Timer? _renewTimer;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool get isLoggedIn => status == AuthStatus.loggedIn;

  /// For the streaming proxy.
  String? tokenProvider() => token?.accessToken;

  // ------------------------------------------------------------- startup

  /// Silent: never asks for biometrics; refresh only when近过期.
  Future<void> init() async {
    token = await _store.loadToken();
    savedAccount = await _store.loadAccount();
    if (token == null) {
      status = AuthStatus.loggedOut;
      _notify();
      return;
    }
    if (token!.needsRefresh(_now().millisecondsSinceEpoch)) {
      final ok = await refresh();
      if (!ok) {
        // Token expired and refresh failed: ask for re-login only when
        // the user actually does something needing auth.
        status = AuthStatus.needsRelogin;
        _notify();
        return;
      }
    }
    status = AuthStatus.loggedIn;
    _scheduleRenewal();
    _fetchUser();
    _notify();
  }

  void _fetchUser() async {
    final t = token;
    if (t == null) return;
    user = await _client.getUserInfo(t);
    _notify();
  }

  // ------------------------------------------------------------- refresh

  /// Refreshes the token pair; returns success.
  Future<bool> refresh() async {
    final t = token;
    if (t == null || _refreshing) return t != null;
    _refreshing = true;
    try {
      final fresh = await _refresher(t);
      if (fresh == null) return false;
      token = fresh;
      await _store.saveToken(fresh);
      _scheduleRenewal();
      return true;
    } catch (_) {
      return false;
    } finally {
      _refreshing = false;
    }
  }

  void _scheduleRenewal() {
    _renewTimer?.cancel();
    final t = token;
    if (t == null) return;
    // Hourly check; refresh kicks in under the 48h threshold.
    _renewTimer = Timer.periodic(const Duration(hours: 1), (_) async {
      final cur = token;
      if (cur == null) return;
      if (cur.needsRefresh(_now().millisecondsSinceEpoch)) {
        final ok = await refresh();
        if (!ok && status == AuthStatus.loggedIn) {
          status = AuthStatus.needsRelogin;
          _notify();
        }
      }
    });
  }

  /// Ensures a usable access token before playback/downloads.
  /// Refreshes if near expiry; on failure transitions to needsRelogin.
  Future<String?> ensureValidToken() async {
    var t = token;
    if (t == null) return null;
    if (t.needsRefresh(_now().millisecondsSinceEpoch)) {
      final ok = await refresh();
      if (!ok) {
        status = AuthStatus.needsRelogin;
        _notify();
        return null;
      }
      t = token;
    }
    return t?.accessToken;
  }

  /// Called by API layers on 401: refresh once, then retry callback.
  Future<T?> on401Retry<T>(Future<T> Function() retry) async {
    final ok = await refresh();
    if (!ok) {
      status = AuthStatus.needsRelogin;
      _notify();
      return null;
    }
    return retry();
  }

  // ------------------------------------------------------------- login

  Future<bool> login(String account, String password,
      {bool rememberPassword = true}) async {
    final performer = _loginPerformer;
    if (performer == null) return false;
    final t = await performer(account, password);
    if (t == null) return false;
    token = t;
    status = AuthStatus.loggedIn;
    await _store.saveToken(t);
    if (rememberPassword && _settings.rememberPassword) {
      await _store.savePassword(account, password);
      savedAccount = account;
    }
    _scheduleRenewal();
    _fetchUser();
    _notify();
    return true;
  }

  /// Completes a login whose token was captured by the webview UI
  /// (mobile path); persists token and optionally credentials.
  Future<void> acceptExternalToken(
    TokenBundle t, {
    String? account,
    String? password,
    bool remember = true,
  }) async {
    token = t;
    status = AuthStatus.loggedIn;
    await _store.saveToken(t);
    if (remember && account != null && password != null) {
      await _store.savePassword(account, password);
      savedAccount = account;
    }
    _scheduleRenewal();
    _fetchUser();
    _notify();
  }

  Future<void> logout({bool wipeCredentials = false}) async {
    _renewTimer?.cancel();
    await _store.clearToken();
    if (wipeCredentials) {
      await _store.wipeCredentials();
      savedAccount = null;
    }
    token = null;
    user = null;
    status = AuthStatus.loggedOut;
    _notify();
  }

  // ------------------------------------------------------------- vault

  /// The saved plaintext password, gated by biometrics when enabled.
  /// This is the ONLY place biometrics are requested.
  Future<String?> unlockPassword({bool forcePrompt = false}) async {
    final pw = await _store.loadPassword();
    if (pw == null) return null;
    if (_settings.biometricProtect || forcePrompt) {
      final ok = await _biometrics.authenticate('解锁已保存的登录密码用于自动登录');
      if (!ok) return null;
    }
    return pw;
  }

  Future<bool> biometricsAvailable() => _biometrics.isAvailable();

  bool get biometricProtect => _settings.biometricProtect;

  bool get rememberPasswordDefault => _settings.rememberPassword;

  set biometricProtect(bool v) {
    _settings.biometricProtect = v;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _renewTimer?.cancel();
    super.dispose();
  }
}
