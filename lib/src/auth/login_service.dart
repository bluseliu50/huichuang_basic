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

/// Script-message channel (Linux/macOS) over which the injected page
/// script pushes the captured token via `window.<name>.postMessage`.
const _tokenChannelName = 'hcTokenChannel';

const _loginUrl = 'https://basic.smartedu.cn/';

/// Direct entry to the platform's login page — the exact URL the portal's
/// 登录 anchor lands on (verified 2026-09-03: single same-tab hop, no
/// query params). The portal entry itself is a JS chain (Xuser-SDK token
/// promise, then location.href) that never fires inside the Windows
/// WebView2 login window (rc.3 stayed frozen on the portal), and the
/// Linux AppImage build died on the click. Windows and Linux therefore
/// skip the portal and land here directly; the injected script already
/// handles this host (fill + submit), and after login the auth page
/// redirects back to basic.smartedu.cn where the token lands in
/// localStorage as usual. macOS keeps the proven portal entry.
const _authLoginUrl = 'https://auth.smartedu.cn/uias/login';

/// WebView2 resolves a relative [CreateConfiguration.userDataFolderWindows]
/// next to the exe — read-only under Program Files, which makes the login
/// webview die with "Edge cannot read or write its data directory". Point
/// it at %APPDATA% instead; other platforms ignore the value.
String get _webview2DataFolder {
  final appdata = Platform.environment['APPDATA'];
  if (Platform.isWindows && appdata != null && appdata.isNotEmpty) {
    return '$appdata\\huichuang_basic\\webview2';
  }
  return 'webview_window_WebView2';
}

/// JS injected on every page load: on the portal (logged out) clicks the
/// 登录 entry; on auth.smartedu.cn fills username/password, ticks the
/// agreement and presses 登录. The slider captcha stays for the human.
/// Independent of that flow, a token watcher polls localStorage on EVERY
/// *.smartedu.cn document and pushes the token the moment it lands — the
/// post-login redirect target under smartedu.cn varies, so the capture
/// must not be tied to basic.smartedu.cn.
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
  // Token push: WebKitGTK >= 2.46 exposes the script message handler ONLY
  // as window.webkit.messageHandlers.<name> (the legacy window.<name>
  // object is gone — verified 2026-09-04 on webkit2gtk-4.1); WKWebView
  // always uses the webkit.messageHandlers form. Try legacy first anyway.
  function __hcPush(v) {
    try {
      var ch = window['$_tokenChannelName'];
      if (ch && ch.postMessage) { ch.postMessage(v); return true; }
      var wk = window.webkit && window.webkit.messageHandlers;
      var h = wk && wk['$_tokenChannelName'];
      if (h && h.postMessage) { h.postMessage(v); return true; }
      var cv = window.chrome && window.chrome.webview;
      if (cv && cv.postMessage) { cv.postMessage(v); return true; }
    } catch (e) {}
    return false;
  }
  // Watcher: any smartedu.cn origin, first token wins. Runs independently
  // of evaluateJavaScript, whose async callback never fires on some
  // WebKitGTK builds.
  function __hcWatch() {
    try {
      if (location.host.indexOf('.smartedu.cn') < 0 &&
          location.host !== 'smartedu.cn') return;
      var v = localStorage.getItem(KEY);
      if (v && v.length > 50 && __hcPush(v)) clearInterval(window.__hcTok);
    } catch (e) {}
  }
  __hcWatch();
  window.__hcTok = setInterval(__hcWatch, 500);
  var tries = 0;
  var timer = setInterval(function () {
    tries++;
    try {
      var host = location.host;
      if (host === 'basic.smartedu.cn') {
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

/// Removes the captured token from the webview's localStorage so a later
/// login attempt can never re-capture a previous session's token.
String tokenClearExpression() =>
    'localStorage.removeItem("$_tokenKey")';

/// Scans the auth page for the platform's own login-failure wording
/// (wrong password, locked account, throttling …) so the app can surface
/// WHY the login failed instead of polling silently for five minutes.
/// Only ever matches on auth.smartedu.cn — the portal page contains no
/// these phrases, and captcha prompts deliberately don't match either.
String loginFailureProbeExpression() => '''
(function () {
  if (location.host !== 'auth.smartedu.cn') return '';
  if (!document.body) return '';
  var phrases = ['密码错误', '账号或密码', '用户名或密码', '密码不正确',
                 '账号不存在', '已被锁定', '已被冻结', '登录失败',
                 '登录异常', '次数过多', '过于频繁'];
  var lines = (document.body.innerText || '').split('\\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (!line || line.length > 60) continue;
    for (var j = 0; j < phrases.length; j++) {
      if (line.indexOf(phrases[j]) >= 0) return line;
    }
  }
  return '';
})()
''';

String _jsEscape(String s) =>
    s.replaceAll('\\', r'\\').replaceAll("'", r"\'").replaceAll('\n', '');

/// Result of a login attempt.
class LoginResult {
  const LoginResult({this.token, this.cancelled = false, this.failure});

  final TokenBundle? token;
  final bool cancelled;

  /// Page-reported failure message (wrong password, lockout …) when the
  /// webview showed an error instead of logging in.
  final String? failure;

  bool get ok => token != null;
}

/// What the wired [LoginPerformer] hands back to AuthController: the token
/// on success, or the failure message to show in the login form.
class LoginOutcome {
  const LoginOutcome(this.token, this.failure);

  final TokenBundle? token;
  final String? failure;
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
    // Fresh webview profile per attempt: a previous account's cookies must
    // never auto-login the next attempt (credential cross-talk).
    await WebviewWindow.clearAll(userDataFolderWindows: _webview2DataFolder);
    final completer = Completer<LoginResult>();
    final webview = await WebviewWindow.create(
      // `const` dropped: the data folder is computed at runtime.
      configuration: CreateConfiguration(
        title: '登录国家中小学智慧教育平台',
        windowHeight: 720,
        windowWidth: 460,
        titleBarTopPadding: 8,
        userDataFolderWindows: _webview2DataFolder,
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

    // Channel push path: the injected script posts the token as soon as
    // the portal writes it — no evaluate round-trip, which can hang
    // forever on WebKitGTK builds whose async JS callbacks die mid-login
    // (GLib criticals in WebKitWebProcess). All three platforms push
    // through __hcPush; the receiving end differs: WebView2 (Windows) has
    // no named script channels, messages arrive via
    // window.chrome.webview.postMessage as plain "onWebMessageReceived".
    void handleTokenPush(dynamic body) {
      debugPrint(
          'HC_LOGIN token push received (${body is String ? body.length : body})');
      final value = body is String &&
              body.length > 2 &&
              body.startsWith('"') &&
              body.endsWith('"')
          ? body.substring(1, body.length - 1)
          : (body is String ? body : null);
      if (value == null || value.length < 50) return;
      try {
        final token = TokenBundle.fromLocalStorage(value);
        unawaited(WebviewWindow.clearAll());
        done(LoginResult(token: token));
      } catch (e) {
        debugPrint('HC_LOGIN pushed token failed to parse: $e');
      }
    }

    if (Platform.isWindows) {
      webview.addOnWebMessageReceivedCallback(handleTokenPush);
    } else {
      webview.registerJavaScriptMessageHandler(_tokenChannelName,
          (_, body) {
        handleTokenPush(body);
      });
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

    webview.launch(Platform.isWindows || Platform.isLinux
        ? _authLoginUrl
        : _loginUrl);

    // Dart-side token poll — fallback only: the primary capture is the
    // channel push above. evaluateJavaScript gets a hard timeout because
    // on some WebKitGTK builds its async callback never fires mid-login
    // and an unanswered invoke would hang this loop forever.
    for (var i = 0; i < 600 && !finished; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (finished) break;
      try {
        final raw = await webview
            .evaluateJavaScript(tokenPollExpression())
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
        if (raw != null && raw != 'null' && raw != '""' && raw.length > 50) {
          final value = raw.startsWith('"') && raw.endsWith('"')
              ? raw.substring(1, raw.length - 1)
              : raw;
          try {
            final token = TokenBundle.fromLocalStorage(value);
            // Reset the profile right after capturing the token so the
            // session never survives into the next login attempt.
            unawaited(WebviewWindow.clearAll());
            done(LoginResult(token: token));
          } catch (_) {}
        }
      } catch (_) {
        // Webview not ready yet — keep polling.
      }
      if (finished || i.isOdd) continue;
      try {
        final raw = await webview
            .evaluateJavaScript(loginFailureProbeExpression())
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
        if (raw is String &&
            raw.length > 2 &&
            raw != 'null' &&
            raw != '""') {
          final msg = raw.startsWith('"') && raw.endsWith('"')
              ? raw.substring(1, raw.length - 1)
              : raw;
          if (msg.isNotEmpty) done(LoginResult(failure: msg));
        }
      } catch (_) {}
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
