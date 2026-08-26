/// Credential + token storage. Secrets live in the platform keystore
/// (macOS Keychain / Android Keystore / iOS Keychain) via
/// flutter_secure_storage; non-secret preferences in shared_preferences.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';

/// Minimal async KV contract so tests can swap in memory.
abstract class SecureKeyValue {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureKV implements SecureKeyValue {
  FlutterSecureKV([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemoryKV implements SecureKeyValue {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class TokenStore {
  TokenStore(this._kv);

  static const _kToken = 'hc_token';
  static const _kPassword = 'hc_password';
  static const _kAccount = 'hc_account';

  final SecureKeyValue _kv;

  Future<TokenBundle?> loadToken() async {
    final raw = await _kv.read(_kToken);
    if (raw == null || raw.isEmpty) return null;
    try {
      return TokenBundle.fromUcJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      await _kv.delete(_kToken);
      return null;
    }
  }

  Future<void> saveToken(TokenBundle t) =>
      _kv.write(_kToken, jsonEncode(t.toUcJson()));

  Future<void> clearToken() => _kv.delete(_kToken);

  Future<String?> loadPassword() => _kv.read(_kPassword);

  Future<void> savePassword(String account, String password) async {
    await _kv.write(_kAccount, account);
    await _kv.write(_kPassword, password);
  }

  Future<String?> loadAccount() => _kv.read(_kAccount);

  Future<void> wipeCredentials() async {
    await _kv.delete(_kPassword);
    await _kv.delete(_kAccount);
  }

  /// Round-trip probe: some Linux desktops run without a Secret Service
  /// (libsecret/keyring), which makes every secure-storage call throw —
  /// callers must degrade to session-only state there.
  Future<bool> storageWritable() async {
    const k = 'hc_storage_probe';
    try {
      await _kv.write(k, 'ok');
      final v = await _kv.read(k);
      await _kv.delete(k);
      return v == 'ok';
    } catch (_) {
      return false;
    }
  }
}

/// Non-secret app settings (biometric toggle etc.).
class AppSettings {
  AppSettings._(this._prefs);

  final SharedPreferences _prefs;

  static Future<AppSettings> load() async =>
      AppSettings._(await SharedPreferences.getInstance());

  static const _kBiometric = 'hc_biometric_protect';
  static const _kRemember = 'hc_remember_password';
  static const _kHwDecode = 'hc_hw_decode';
  static const _kLastTm = 'hc_last_teachingmaterial';

  bool get biometricProtect => _prefs.getBool(_kBiometric) ?? true;
  set biometricProtect(bool v) => _prefs.setBool(_kBiometric, v);

  bool get rememberPassword => _prefs.getBool(_kRemember) ?? true;
  set rememberPassword(bool v) => _prefs.setBool(_kRemember, v);

  bool get hardwareDecode => _prefs.getBool(_kHwDecode) ?? true;
  set hardwareDecode(bool v) => _prefs.setBool(_kHwDecode, v);

  String? get lastTeachingMaterialId => _prefs.getString(_kLastTm);
  set lastTeachingMaterialId(String? v) {
    if (v == null) {
      _prefs.remove(_kLastTm);
    } else {
      _prefs.setString(_kLastTm, v);
    }
  }
}
