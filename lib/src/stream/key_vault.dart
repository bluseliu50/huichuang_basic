/// Key derivation for the platform's HLS AES-128 key service
/// (ndvideo-key.ykt.eduyun.cn), verified end-to-end 2026-08.
///
/// Protocol:
///  1. `GET {keyUri}/signs` with X-ND-AUTH → `{"nonce": "..."}`;
///  2. `sign = md5(nonce + keyId).hex().substring(0, 16)`;
///  3. `GET {keyUri}?nonce={nonce}&sign={sign}` with X-ND-AUTH
///     → `{"key": "<base64>"}`;
///  4. real 16-byte key = AES-128-ECB decrypt of the base64 blob using the
///     16-char `sign` as key, PKCS7-unpadded.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/ecb.dart';

class KeyVault {
  KeyVault._();

  /// Worked example (live session, see test fixtures):
  /// nonce `1787490052543:63Tjc0qk` + keyId `62505e3f635d4d93bca91f5c541a83ae`
  /// → `7df1957a79bdd8fc`.
  static String deriveSign(String nonce, String keyId) =>
      md5.convert(utf8.encode(nonce + keyId)).toString().substring(0, 16);

  /// Decrypts the base64-wrapped key blob with AES-128-ECB/PKCS7.
  static Uint8List decryptKey(String base64Key, String sign) {
    final cipherText = base64.decode(base64Key);
    if (cipherText.length % 16 != 0 || cipherText.isEmpty) {
      throw const FormatException('key blob not AES-block sized');
    }
    final cipher = ECBBlockCipher(AESEngine())
      ..init(false, KeyParameter(utf8.encode(sign)));
    final out = Uint8List(cipherText.length);
    for (var off = 0; off < cipherText.length; off += 16) {
      final block = cipher.process(Uint8List.fromList(
          cipherText.sublist(off, off + 16)));
      out.setRange(off, off + 16, block);
    }
    return _stripPkcs7(out);
  }

  static Uint8List _stripPkcs7(Uint8List padded) {
    if (padded.isEmpty) throw const FormatException('empty key');
    final n = padded.last;
    if (n < 1 || n > 16 || n > padded.length) {
      throw const FormatException('bad PKCS7 padding');
    }
    for (var i = padded.length - n; i < padded.length; i++) {
      if (padded[i] != n) throw const FormatException('bad PKCS7 padding');
    }
    return Uint8List.sublistView(padded, 0, padded.length - n);
  }
}
