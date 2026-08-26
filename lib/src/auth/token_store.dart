/// Credential + token storage. Secrets live in the platform keystore
/// (macOS Keychain / Android Keystore / iOS Keychain) via
/// flutter_secure_storage; non-secret preferences in shared_preferences.
library;

import 'dart:convert';
import 'dart:io';
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

/// Best-effort token cache for hosts WITHOUT secure storage (Linux
/// desktops lacking a Secret Service). XOR+base64 obfuscated JSON under
/// the user config dir — explicitly NOT a secret vault, and the plaintext
/// password is NEVER written here; only the token bundle plus the account
/// name for prefill. With a working keystore this cache is not used.
class TokenFileCache {
  TokenFileCache([File? file]) : _override = file;

  final File? _override;

  static const _key = 'huichuang-basic-session-v1';

  File? _file() {
    final o = _override;
    if (o != null) return o;
    final env = Platform.environment;
    final base =
        env['XDG_CONFIG_HOME'] ?? (env['HOME'] != null ? '${env['HOME']}/.config' : null);
    if (base == null) return null;
    return File('$base/huichuang_basic/session.bin');
  }

  Future<void> save(TokenBundle t, String? account) async {
    final f = _file();
    if (f == null) return;
    final json = jsonEncode({
      'account': account,
      'token': t.toUcJson(),
    });
    final obfuscated = utf8.encode(json).asMap().entries
        .map((e) => e.value ^ _key.codeUnitAt(e.key % _key.length))
        .toList();
    await f.parent.create(recursive: true);
    await f.writeAsString(base64Encode(obfuscated), flush: true);
  }

  Future<(TokenBundle, String?)?> load() async {
    final f = _file();
    if (f == null || !await f.exists()) return null;
    try {
      final raw = base64Decode(await f.readAsString());
      final json = utf8.decode(
          raw.asMap().entries.map((e) => e.value ^ _key.codeUnitAt(e.key % _key.length)).toList());
      final map = jsonDecode(json) as Map<String, dynamic>;
      return (
        TokenBundle.fromUcJson((map['token'] as Map).cast<String, dynamic>()),
        map['account'] as String?
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    final f = _file();
    if (f != null && await f.exists()) await f.delete();
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
