/// System biometric gate (Touch ID / Face ID / BiometricPrompt / Hello).
///
/// Policy: biometrics NEVER gate app launch — only access to the saved
/// plaintext password in the vault (auto-fill re-login, viewing the saved
/// account, manual lock).
library;

import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:local_auth_darwin/local_auth_darwin.dart';

abstract class BiometricGate {
  Future<bool> isAvailable();
  Future<bool> authenticate(String reason);
}

class SystemBiometricGate implements BiometricGate {
  SystemBiometricGate([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isAvailable() async {
    try {
      final can = await _auth.canCheckBiometrics;
      final supported = await _auth.isDeviceSupported();
      return can && supported;
    } catch (e) {
      debugPrint('biometric availability check failed: $e');
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        authMessages: const <AuthMessages>[
          AndroidAuthMessages(
            signInTitle: '验证以使用已保存的密码',
            cancelButton: '取消',
          ),
          IOSAuthMessages(
            cancelButton: '取消',
            localizedFallbackTitle: '使用密码',
          ),
        ],
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      debugPrint('biometric authenticate failed: $e');
      return false;
    }
  }
}

/// Test double.
class FakeBiometricGate implements BiometricGate {
  FakeBiometricGate({this.available = true, this.shouldPass = true});

  bool available;
  bool shouldPass;
  int calls = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    calls++;
    return shouldPass;
  }
}

@visibleForTesting
String biometricUnlockReason() => '解锁已保存的登录密码用于自动登录';
