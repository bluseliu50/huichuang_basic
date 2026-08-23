import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    if (dart.library.io) 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_controller.dart';
import '../../auth/login_service.dart' as svc;

/// Entry point used across the app: shows the login sheet/card.
Future<void> showLoginCard(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const LoginCard(),
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
  String? _hint;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final auth = context.read<AuthController>();
    final account = auth.savedAccount;
    if (account != null) _account.text = account;
    // Vault access: biometrics gate ONLY here, never at startup.
    if (account != null) {
      final pw = await auth.unlockPassword();
      if (pw != null && mounted) _password.text = pw;
    }
  }

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _start() async {
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
    try {
      if (!kIsWeb &&
          (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
        final ok = await auth.login(account, password);
        if (!mounted) return;
        Navigator.of(context).pop();
        if (!ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('登录未完成')),
          );
        }
      } else {
        // Mobile: widget-based webview sheet.
        final token =
            await _mobileWebViewLogin(account, password);
        if (!mounted) return;
        if (token != null) {
          await auth.acceptExternalToken(
            token,
            account: account,
            password: password,
            remember: auth.rememberPasswordDefault,
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
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 8,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
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
      body: InAppWebView(
        initialUrlRequest:
            URLRequest(url: WebUri('https://basic.smartedu.cn/')),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          userAgent:
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125 Mobile Safari/537.36',
        ),
        onWebViewCreated: (c) {
          _controller = c;
          _startPolling();
        },
        onLoadStop: (c, url) async {
          await c.evaluateJavascript(
              source: svc.credentialInjection(widget.account, widget.password));
        },
      ),
    );
  }
}
