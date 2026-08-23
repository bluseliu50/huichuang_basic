import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:huichuang_basic/src/stream/key_vault.dart';
import 'package:huichuang_basic/src/stream/proxy.dart';

/// Verified live session values (2026-08-23, keyId of 大青树下的小学).
const _nonce = '1787490052543:63Tjc0qk';
const _keyId = '62505e3f635d4d93bca91f5c541a83ae';
const _sign = '7df1957a79bdd8fc';
const _b64Key = 'gJ/VTZg4652QUE05QrafoDJXCzh4LMPJKUw/1cWOhEI=';
const _expectedKey = '43bc6fe335b84b37';

void main() {
  group('KeyVault', () {
    test('derives the exact sign from the live session', () {
      expect(KeyVault.deriveSign(_nonce, _keyId), _sign);
    });

    test('AES-128-ECB decrypts to the 16-char ASCII key', () {
      final key = KeyVault.decryptKey(_b64Key, _sign);
      expect(utf8.decode(key), _expectedKey);
      expect(key, hasLength(16));
    });

    test('rejects malformed padding', () {
      // ECB-decrypt of the blob with a WRONG sign yields garbage padding.
      expect(() => KeyVault.decryptKey(_b64Key, '0000000000000000'),
          throwsFormatException);
    });
  });

  group('StreamProxy', () {
    late StreamProxy proxy;

    setUp(() async {
      proxy = StreamProxy(tokenProvider: () => 'TESTTOKEN', allowLoopbackUpstream: true);
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
    });

    test('rewrites a real playlist: key + segments point to the proxy',
        () async {
      final body = File('test/fixtures/playlist_head.m3u8').readAsStringSync();
      const playlistUrl =
          'https://r1-ndr-private.ykt.cbern.com.cn/edu_product/esp/assets/x/videos/master.m3u8';
      final rewritten =
          proxy.rewritePlaylist(body, 'res1', Uri.parse(playlistUrl));

      // No upstream host leaks into URIs.
      expect(rewritten, isNot(contains('ndvideo-key.ykt.eduyun.cn/v1/resource_keys/62505e3f635d4d93bca91f5c541a83ae",IV')));
      expect(rewritten, isNot(contains('.ts\nhttps://r1')));

      // Key line rewritten to local key endpoint with upstream URI encoded.
      expect(
          rewritten,
          contains(RegExp(
              r'#EXT-X-KEY:METHOD=AES-128,URI="http://127\.0\.0\.1:\d+/hls/res1/key\?u=https%3A%2F%2Fndvideo-key\.ykt\.eduyun\.cn%2Fv1%2Fresource_keys%2F62505e3f635d4d93bca91f5c541a83ae",IV=0x00000000000000000000000000000000')));

      // Relative segment names resolved against playlist URL and proxied.
      expect(
          rewritten,
          contains(RegExp(
              r'http://127\.0\.0\.1:\d+/hls/x/seg\?u=https%3A%2F%2Fr1-ndr-private\.ykt\.cbern\.com\.cn%2Fedu_product%2Fesp%2Fassets%2Fx%2Fvideos%2F\S+-00000\.ts')));

      // IV and other tags survive untouched.
      expect(rewritten, contains('#EXT-X-PLAYLIST-TYPE:VOD'));
      expect(rewritten, contains('#EXT-X-VERSION:3'));
    });

    test('full key dance against a fake key server', () async {
      // Fake key service implementing the /signs + ?nonce&sign protocol.
      final keyServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      keyServer.listen((req) async {
        final path = req.uri.path;
        if (path.endsWith('/signs')) {
          req.response.headers.contentType = ContentType.json;
          req.response.write('{"nonce":"$_nonce"}');
        } else {
          // The proxy must present the correct sign to get the real blob.
          final sign = req.uri.queryParameters['sign'];
          req.response.headers.contentType = ContentType.json;
          req.response.write(sign == _sign
              ? '{"key":"$_b64Key"}'
              : '{"key":"${base64Encode(Uint8List(16))}"}');
        }
        await req.response.close();
      });

      // Fake playlist server + segment server.
      final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      cdn.listen((req) async {
        if (req.uri.path.endsWith('.m3u8')) {
          // Auth required, like the real private CDN.
          if (req.headers.value('X-ND-AUTH') != 'TESTTOKEN') {
            req.response.statusCode = 401;
            await req.response.close();
            return;
          }
          req.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          req.response.write('#EXTM3U\n'
              '#EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1:${keyServer.port}/v1/resource_keys/$_keyId",IV=0x00000000000000000000000000000000\n'
              '#EXTINF:10.0,\n'
              'seg-00000.ts\n'
              '#EXT-X-ENDLIST\n');
        } else {
          req.response.headers.contentType = ContentType.binary;
          req.response.add(List.filled(4096, 7));
        }
        await req.response.close();
      });

      proxy.register(
          'resX', [Uri.parse('http://127.0.0.1:${cdn.port}/video/master.m3u8')]);

      final client = HttpClient();

      // 1. Playlist: rewritten through the proxy.
      final plReq = await client.getUrl(proxy.playlistUrl('resX'));
      final plRes = await plReq.close();
      expect(plRes.statusCode, 200);
      final pl = await plRes.transform(utf8.decoder).join();
      expect(pl, startsWith('#EXTM3U'));
      expect(pl, contains('/hls/resX/key?u='));
      expect(pl, contains('/hls/x/seg?u='));

      // 2. Key: the dance yields exactly the verified 16-byte key.
      final keyLine =
          RegExp(r'URI="([^"]+)"').firstMatch(pl)!.group(1)!;
      final keyReq = await client.getUrl(Uri.parse(keyLine));
      final keyRes = await keyReq.close();
      expect(keyRes.statusCode, 200);
      final keyBytes = await keyRes.fold<List<int>>(
          <int>[], (acc, d) => acc..addAll(d));
      expect(utf8.decode(keyBytes), _expectedKey);
      expect(keyBytes, hasLength(16));

      // 3. Segment: proxied bytes pass through.
      final segLine =
          RegExp(r'^(http://127\.0\.0\.1:\d+/hls/x/seg\?u=\S+)$', multiLine: true)
              .firstMatch(pl)!
              .group(1)!;
      final segReq = await client.getUrl(Uri.parse(segLine));
      final segRes = await segReq.close();
      expect(segRes.statusCode, 200);
      final segBytes = await segRes.fold<List<int>>(
          <int>[], (acc, d) => acc..addAll(d));
      expect(segBytes, hasLength(4096));

      await keyServer.close();
      await cdn.close();
    });

    test('playlist failover skips a dead mirror', () async {
      final alive = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      alive.listen((req) async {
        req.response.write('#EXTM3U\n#EXT-X-ENDLIST\n');
        await req.response.close();
      });
      final deadPort = await _findDeadPort();

      proxy.register('resF', [
        Uri.parse('http://127.0.0.1:$deadPort/a.m3u8'),
        Uri.parse('http://127.0.0.1:${alive.port}/b.m3u8'),
      ]);

      final client = HttpClient();
      final req = await client.getUrl(proxy.playlistUrl('resF'));
      final res = await req.close();
      expect(res.statusCode, 200);
      final body = await res.transform(utf8.decoder).join();
      expect(body, contains('#EXTM3U'));
      await alive.close();
    });
  });
}

Future<int> _findDeadPort() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}
