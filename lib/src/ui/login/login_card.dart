import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    if (dart.library.io) 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_controller.dart';
import '../../auth/login_service.dart' as svc;

/// Entry point used across the app: shows the centered login dialog.
Future<void> showLoginCard(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const Dialog(child: LoginCard()),
  );
}

class LoginCard extends StatefulWidget {
  const LoginCard({super.key});

  @override
  State<LoginCard> createState() => _LoginCardState();
}

class _LoginCardState extends State<LoginCard> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _biometricsAvailable = false;
  String? _hint;

  @override
  void initState() {
    super.initState();
    _prefill();
    context
        .read<AuthController>()
        .biometricsAvailable()
        .then((v) => mounted ? setState(() => _biometricsAvailable = v) : null);
  }

  Future<void> _prefill() async {
    final auth = context.read<AuthController>();
    final account = auth.savedAccount;
    if (account == null) return; // first login: nothing saved yet
    _account.text = account;
    // Vault access: biometrics gate ONLY here, never at startup.
    final pw = await auth.unlockPassword();
    if (!mounted || pw == null) return; // cancelled → manual entry below
    _password.text = pw;
    // Unlocked through biometrics → go straight to the captcha window.
    // (With protection off there is no proof to reuse; user taps 登录.)
    if (auth.biometricProtect) {
      await _start(alreadyVerified: true);
    }
  }

  Future<void> _start({bool alreadyVerified = false}) async {
    final account = _account.text.trim();
    final password = _password.text;
    if (account.isEmpty || password.isEmpty) {
      setState(() => _hint = '请输入账号和密码');
      return;
    }
    setState(() {
      _busy = true;
      _hint = null;
    });
    final auth = context.read<AuthController>();
    // Marriott-style gate: with protection on, the 登录 tap verifies
    // biometrics first; a cancelled prompt aborts. Manual entries still
    // overwrite the saved credentials on success. The auto-login path
    // arrives alreadyVerified (its fingerprint proof just succeeded).
    if (!alreadyVerified && auth.biometricProtect) {
      final ok = await auth.authenticateForLogin();
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _busy = false;
          _hint = '指纹验证未通过，可手动输入账号密码后重试';
        });
        return;
      }
    }
    // Credentials confirmed here always overwrite the vault entry.
    final remember = auth.rememberPasswordDefault;
    try {
      if (!kIsWeb &&
          (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('正在打开官方登录页，请耐心等待滑块人机验证弹出后手动完成')),
        );
        final ok =
            await auth.login(account, password, rememberPassword: remember);
        if (!mounted) return;
        Navigator.of(context).pop();
        if (!ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('登录未完成')),
          );
        }
      } else {
        // Mobile: widget-based webview sheet (shows its own waiting banner).
        final token = await _mobileWebViewLogin(account, password);
        if (!mounted) return;
        if (token != null) {
          await auth.acceptExternalToken(
            token,
            account: account,
            password: password,
            remember: remember,
          );
          if (mounted) Navigator.of(context).pop();
        } else {
          setState(() {
            _busy = false;
            _hint = '登录未完成，请重试';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _hint = '出错：$e';
        });
      }
    }
  }

  Future<dynamic> _mobileWebViewLogin(String account, String password) {
    return Navigator.of(context).push(MaterialPageRoute<dynamic>(
      fullscreenDialog: true,
      builder: (_) => MobileLoginSheet(account: account, password: password),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('登录国家中小学智慧教育平台',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '打开官方登录页并自动填入账号密码，滑块验证需要你手动完成。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _account,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: '手机号 / 通行证ID',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '密码',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            if (_hint != null) ...[
              const SizedBox(height: 8),
              Text(_hint!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
            ],
            if (_biometricsAvailable) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.fingerprint),
                title: const Text('生物识别保护'),
                value: auth.biometricProtect,
                onChanged: (v) => auth.biometricProtect = v,
              ),
              Text(
                '开启后，登录及读取、保存密码需先验证指纹／面容；启动应用时不会询问。取消验证可手动输入账号密码。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _start,
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mobile webview login sheet (flutter_inappwebview).
class MobileLoginSheet extends StatefulWidget {
  const MobileLoginSheet(
      {super.key, required this.account, required this.password});

  final String account;
  final String password;

  @override
  State<MobileLoginSheet> createState() => _MobileLoginSheetState();
}

class _MobileLoginSheetState extends State<MobileLoginSheet> {
  InAppWebViewController? _controller;
  bool _gotToken = false;
  bool _pageEverLoaded = false;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_gotToken) return;
      final c = _controller;
      if (c == null) return;
      try {
        final raw = await c.evaluateJavascript(
            source: svc.tokenPollExpression());
        final token = svc.tryParseToken(raw?.toString());
        if (token != null) {
          _gotToken = true;
          _poll?.cancel();
          // Reset the profile right after capture so this session never
          // survives into the next login attempt (cross-account reuse).
          await CookieManager.instance().deleteAllCookies();
          try {
            await _controller?.evaluateJavascript(
                source: svc.tokenClearExpression());
          } catch (_) {}
          if (mounted) Navigator.of(context).pop(token);
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录'),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: _pageEverLoaded
                        ? const Icon(Icons.check, size: 14)
                        : const CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _pageEverLoaded
                          ? '账号已填入，请在滑块人机验证弹出后手动完成验证'
                          : '正在打开官方登录页，请耐心等待滑块人机验证弹出…',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest:
                  URLRequest(url: WebUri('https://basic.smartedu.cn/')),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                userAgent:
                    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125 Mobile Safari/537.36',
              ),
              onWebViewCreated: (c) async {
                _controller = c;
                // Fresh cookie jar per attempt: a previous account's
                // session must never auto-login the next attempt.
                await CookieManager.instance().deleteAllCookies();
              },
              onLoadStop: (c, url) async {
                if (!_pageEverLoaded) {
                  setState(() => _pageEverLoaded = true);
                  // Drop any token left in localStorage BEFORE polling
                  // starts, so only THIS attempt's fresh token is captured.
                  await c.evaluateJavascript(
                      source: svc.tokenClearExpression());
                  _startPolling();
                }
                await c.evaluateJavascript(
                    source: svc.credentialInjection(widget.account, widget.password));
              },
            ),
          ),
        ],
      ),
    );
  }
}
