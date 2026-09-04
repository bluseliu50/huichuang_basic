// ignore_for_file: avoid_print
// Channel + close pipeline probe: reproduces the login capture machinery
// WITHOUT the real site. Verifies three links at once:
//
//   1. registerJavaScriptMessageHandler -> window.<name>.postMessage pipeline
//   2. evaluateJavaScript round-trip (+ handler exposure diagnostics)
//   3. webview.close() tears the window down without crashing the app or
//      the WebKitWebProcess (NVIDIA EGL teardown; hc8 DMABUF renderer fix)
//
//   fvm flutter run -t tool/webchannel_probe.dart -d linux
//
// PASS = "HC_PROBE2 push received" + "HC_PROBE2 close ok" + "HC_PROBE2 exit",
// no window left behind, no coredump.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';

const _channel = 'hcTokenChannel';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox());
  final webview = await WebviewWindow.create(
    configuration: const CreateConfiguration(
      title: 'hc probe2',
      windowHeight: 400,
      windowWidth: 460,
    ),
  );
  final push = Completer<String>();
  webview.registerJavaScriptMessageHandler(_channel, (_, body) {
    print('HC_PROBE2 push received: $body');
    if (!push.isCompleted) push.complete(body?.toString());
  });
  // Same push order as the login flow's __hcPush, minus its third
  // (Windows-only window.chrome.webview) path: legacy window.<name> first,
  // then the WKWebView-style window.webkit.messageHandlers.<name>.
  webview.addScriptToExecuteOnDocumentCreated('''
(function () {
  function push(v) {
    try {
      var ch = window['$_channel'];
      if (ch && ch.postMessage) { ch.postMessage(v); return 'legacy'; }
      var h = window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers['$_channel'];
      if (h && h.postMessage) { h.postMessage(v); return 'wkstyle'; }
      return 'no-channel';
    } catch (e) { return 'err:' + e; }
  }
  var tries = 0;
  var t = setInterval(function () {
    tries++;
    var r = push('"fake-token-from-probe-0123456789"');
    if (r !== 'no-channel' || tries > 20) {
      clearInterval(t);
      window.__hcProbeResult = r;
    }
  }, 500);
})();
''');
  webview.launch('https://example.com/');

  // Diagnose: where does WebKitGTK expose script message handlers now?
  await Future<void>.delayed(const Duration(seconds: 3));
  try {
    final t = await webview.evaluateJavaScript('(function(){'
            'var out={legacy:typeof window["hcTokenChannel"]};'
            'try{out.wk=typeof window.webkit;}catch(e){out.wk="err";}'
            'try{out.mh=(window.webkit&&window.webkit.messageHandlers)?'
            'Object.getOwnPropertyNames(window.webkit.messageHandlers):"none";}'
            'catch(e){out.mh="err";}'
            'try{out.pushResult=window.__hcProbeResult;}catch(e){}'
            'return JSON.stringify(out);})()')
        .timeout(const Duration(seconds: 5), onTimeout: () => 't-timeout');
    print('HC_PROBE2 exposure: $t');
  } catch (e) {
    print('HC_PROBE2 exposure threw: $e');
  }

  // Independent link check: evaluate round-trip on the loaded page.
  try {
    final ev = await webview
        .evaluateJavaScript('"eval-ok"')
        .timeout(const Duration(seconds: 5), onTimeout: () => 'eval-timeout');
    print('HC_PROBE2 evaluate: $ev');
  } catch (e) {
    print('HC_PROBE2 evaluate threw: $e');
  }

  final body = await push.future.timeout(const Duration(seconds: 20),
      onTimeout: () => 'PUSH-NEVER-ARRIVED');
  print('HC_PROBE2 push: $body');

  await Future<void>.delayed(const Duration(seconds: 1));
  try {
    webview.close();
    print('HC_PROBE2 close ok');
  } catch (e) {
    print('HC_PROBE2 close threw: $e');
  }
  await Future<void>.delayed(const Duration(seconds: 3));
  print('HC_PROBE2 exit');
  exit(0);
}
