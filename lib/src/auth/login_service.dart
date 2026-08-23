/// WebView-based login (PiliPlus pattern).
///
/// The app opens the platform's real login page, auto-fills the saved
/// credentials and submits; the USER solves the slider captcha manually.
/// The token is captured from localStorage (`ND_UC_AUTH-…&ncet-xedu&token`)
/// and returned. Mobile uses flutter_inappwebview in a dialog; desktop uses
/// desktop_webview_window.
library;

import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart'
    if (dart.library.io) 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';

import '../api/models.dart';

const _tokenKey =
    'ND_UC_AUTH-e5649925-441d-4a53-b525-51a2f1c4e0a8&ncet-xedu&token';

const _loginUrl = 'https://basic.smartedu.cn/';

/// JS injected on every page load: on the portal (logged out) clicks the
/// 登录 entry; on auth.smartedu.cn fills username/password, ticks the
/// agreement and presses 登录. The slider captcha stays for the human.
String credentialInjection(String account, String password) {
  final acc = _jsEscape(account);
  final pass = _jsEscape(password);
  return '''
(function () {
  if (window.__hcLogin != null) return; window.__hcLogin = 1;
  var KEY = '$_tokenKey';
  function setv(sel, v) {
    var el = document.querySelector(sel); if (!el) return false;
    var d = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
    d.call(el, v);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  }
  var tries = 0;
  var timer = setInterval(function () {
    tries++;
    try {
      var host = location.host;
      if (host === 'basic.smartedu.cn') {
        if (localStorage.getItem(KEY)) { clearInterval(timer); return; }
        var links = Array.prototype.slice.call(document.querySelectorAll('a'))
          .filter(function (a) { return (a.textContent || '').trim() === '登录'; });
        if (links.length) { clearInterval(timer); links[0].click(); }
      } else if (host === 'auth.smartedu.cn') {
        if (window.__hcFilled) return;
        if (setv('#username', '$acc') && setv('#tmpPassword', '$pass')) {
          window.__hcFilled = true;
          var cb = document.querySelector('#agreementCheckbox');
          if (cb && !cb.checked) cb.click();
          clearInterval(timer);
          setTimeout(function () {
            var btns = Array.prototype.slice.call(document.querySelectorAll('button'))
              .filter(function (b) { return (b.textContent || '').trim().indexOf('登录') === 0; });
            if (btns.length) btns[btns.length - 1].click();
          }, 400);
        }
      }
    } catch (e) {}
    if (tries > 40) clearInterval(timer);
  }, 750);
})();
''';
}

String tokenPollExpression() =>
    'localStorage.getItem("$_tokenKey")';

String _jsEscape(String s) =>
    s.replaceAll('\\', r'\\').replaceAll("'", r"\'").replaceAll('\n', '');

/// Result of a login attempt.
class LoginResult {
  const LoginResult({this.token, this.cancelled = false});

  final TokenBundle? token;
  final bool cancelled;

  bool get ok => token != null;
}

abstract class LoginService {
  Future<LoginResult> login({
    required String account,
    required String password,
    void Function(String message)? onStatus,
  });
}

/// Desktop (macOS/Windows/Linux) implementation.
class DesktopLoginService implements LoginService {
  @override
  Future<LoginResult> login({
    required String account,
    required String password,
    void Function(String message)? onStatus,
  }) async {
    if (!await WebviewWindow.isWebviewAvailable()) {
      return const LoginResult(cancelled: true);
    }
    final completer = Completer<LoginResult>();
    final webview = await WebviewWindow.create(
      configuration: const CreateConfiguration(
        title: '登录国家中小学智慧教育平台',
        windowHeight: 720,
        windowWidth: 460,
        titleBarTopPadding: 8,
      ),
    );

    var finished = false;
    void done(LoginResult r) {
      if (finished) return;
      finished = true;
      if (!completer.isCompleted) completer.complete(r);
      try {
        webview.close();
      } catch (_) {}
    }

    webview.setOnUrlRequestCallback((url) {
      if (url.contains('basic.smartedu.cn')) {
        onStatus?.call('等待登录完成…');
      }
      return true;
    });

    webview.addScriptToExecuteOnDocumentCreated(
        credentialInjection(account, password));

    unawaited(webview.onClose.then((_) {
      done(const LoginResult(cancelled: true));
    }));

    webview.launch(_loginUrl);

    // Dart-side token poll (works on all desktop backends).
    for (var i = 0; i < 300 && !finished; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        final raw = await webview.evaluateJavaScript(tokenPollExpression());
        if (raw != null && raw != 'null' && raw != '""' && raw.length > 50) {
          final value = raw.startsWith('"') && raw.endsWith('"')
              ? raw.substring(1, raw.length - 1)
              : raw;
          try {
            done(LoginResult(token: TokenBundle.fromLocalStorage(value)));
          } catch (_) {}
        }
      } catch (_) {
        // Webview not ready yet — keep polling.
      }
    }
    done(const LoginResult(cancelled: true));
    return completer.future;
  }
}

/// Factory: picks the implementation for the current platform.
LoginService platformLoginService() {
  if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return DesktopLoginService();
  }
  // Mobile implementation lives in the UI layer (needs a widget route):
  // see ui/login/login_page.dart.
  throw UnsupportedError('use MobileLoginPage on mobile platforms');
}

/// Parses the raw localStorage value; exposed for the mobile UI path.
TokenBundle? tryParseToken(String? raw) {
  if (raw == null) return null;
  final value =
      raw.startsWith('"') && raw.endsWith('"') && raw.length > 1
          ? raw.substring(1, raw.length - 1)
          : raw;
  if (value.length < 50) return null;
  try {
    return TokenBundle.fromLocalStorage(value);
  } catch (_) {
    return null;
  }
}
