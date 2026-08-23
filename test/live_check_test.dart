import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/live_check.dart';

/// Runs the real-platform proxy check when HC_TOKEN is provided; skips
/// otherwise so CI stays green without credentials.
///
/// Deliberately does NOT initialize the widget binding: it installs an
/// HttpOverrides that fakes every request with 400, which would defeat the
/// point of this live check.
void main() {
  final token = Platform.environment['HC_TOKEN'];

  test('live proxy check against basic.smartedu.cn', () async {
    if (token == null || token.isEmpty) {
      // ignore: avoid_print
      print('HC_TOKEN not set — skipping live check');
      return;
    }
    await runLiveCheck(token: token);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
