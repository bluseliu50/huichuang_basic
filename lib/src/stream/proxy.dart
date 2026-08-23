/// Local loopback HTTP proxy that makes the platform's private CDN
/// playable/downloadable by media_kit (mpv) and pdfrx.
///
/// Responsibilities — the linchpin of the "video always plays" goal:
///  * inject `X-ND-AUTH` on every upstream request;
///  * rewrite HLS playlists so segment/key URLs point back here;
///  * perform the key nonce/sign dance and serve the raw 16-byte AES key;
///  * fail over r1 → r2 → r3 CDN nodes with retries (both for playlists
///    and per-segment), which is what the official web player lacks;
///  * stream PDFs / arbitrary docs with Range support.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'key_vault.dart';

class StreamProxy {
  StreamProxy({
    String? Function()? tokenProvider,
    Future<void> Function(String rawTokenJson)? onLoginCallback,
    bool allowLoopbackUpstream = false,
  })  : _tokenProvider = tokenProvider,
        _onLoginCallback = onLoginCallback,
        _allowLoopbackUpstream = allowLoopbackUpstream;

  /// Tests only: permits 127.0.0.1 upstreams (fake CDN servers).
  final bool _allowLoopbackUpstream;

  static const _privateNodePattern = '-ndr-private.ykt.cbern.com.cn';
  static final _nodePrefix = RegExp(r'^https://r[123]-ndr-private');

  final String? Function()? _tokenProvider;
  final Future<void> Function(String rawTokenJson)? _onLoginCallback;

  HttpServer? _server;
  final _upstream = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 60),
  ));
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  final Map<String, List<Uri>> _streams = {};
  final Map<String, Uint8List> _keyCache = {};
  final Map<String, int> _preferredNode = {};

  int? get port => _server?.port;
  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.idleTimeout = const Duration(seconds: 180);
    _listen();
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _streams.clear();
    _keyCache.clear();
    await s?.close(force: true);
  }

  /// Clears in-memory key cache (settings action).
  void clearCaches() {
    _keyCache.clear();
  }

  /// Register the playable mirrors for a resource before opening it.
  void register(String resId, List<Uri> storages) {
    _streams[resId] = List.of(storages);
  }

  /// Base URL for the (rewritten) master playlist of a resource.
  Uri playlistUrl(String resId) =>
      Uri.parse('http://127.0.0.1:$port/hls/$resId/index.m3u8');

  /// URL for a private-CDN document (pdf/ppt/…) through the proxy.
  Uri fileUrl(Uri upstream) =>
      Uri.parse('http://127.0.0.1:$port/file?u=${Uri.encodeComponent(upstream.toString())}');

  void _listen() async {
    await for (final req in _server!) {
      try {
        await _handle(req);
      } catch (e) {
        _fail(req, 502, 'proxy error: $e');
      }
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.pathSegments;
    if (req.method == 'POST' && req.uri.path == '/auth-callback') {
      final body = await utf8.decoder.bind(req).join();
      req.response.statusCode = 204;
      await req.response.close();
      await _onLoginCallback?.call(body);
      return;
    }
    if (req.method != 'GET') {
      _fail(req, 405, 'method not allowed');
      return;
    }

    if (path.length >= 3 && path[0] == 'hls') {
      final resId = path[1];
      switch (path[2]) {
        case 'index.m3u8':
          return _servePlaylist(req, resId);
        case 'key':
          return _serveKey(req, resId);
        case 'seg':
          return _serveStream(req, resId, req.uri.queryParameters['u']);
      }
    }
    if (path.isNotEmpty && (path[0] == 'pdf' || path[0] == 'file')) {
      return _serveStream(req, null, req.uri.queryParameters['u']);
    }
    _fail(req, 404, 'unknown route ${req.uri}');
  }

  // ---------------------------------------------------------------- playlist

  Future<void> _servePlaylist(HttpRequest req, String resId) async {
    final variant = req.uri.queryParameters['u'];
    List<Uri> candidates;
    if (variant != null) {
      candidates = [Uri.parse(variant)];
    } else {
      final storages = _streams[resId];
      if (storages == null || storages.isEmpty) {
        _fail(req, 404, 'resource not registered: $resId');
        return;
      }
      candidates = storages;
    }

    String? body;
    Uri? okUri;
    Object? lastErr;
    for (var round = 0; round < 2 && body == null; round++) {
      for (final uri in candidates) {
        try {
          body = await _fetchText(uri);
          okUri = uri;
          break;
        } catch (e) {
          lastErr = e;
        }
      }
    }
    if (body == null) {
      _fail(req, 502, 'playlist fetch failed ($lastErr)');
      return;
    }
    if (okUri != null) {
      _preferredNode[resId] = _nodeIndex(okUri);
    }

    final rewritten = rewritePlaylist(body, resId, okUri ?? candidates.first);
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
    req.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    req.response.write(rewritten);
    await req.response.close();
  }

  /// Rewrites a playlist: EXT-X-KEY URI → local key endpoint, every URI line
  /// (segment or nested playlist) → local proxy URL. Handles master playlists
  /// and relative names.
  String rewritePlaylist(String body, String resId, Uri playlistUri) {
    final out = StringBuffer();
    for (final rawLine in const LineSplitter().convert(body)) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        out.writeln();
        continue;
      }
      if (line.startsWith('#')) {
        final keyUriMatch =
            RegExp(r'^(.*URI=")([^"]+)(".*)$').firstMatch(line);
        if (keyUriMatch != null) {
          final upstream = playlistUri.resolve(keyUriMatch.group(2)!);
          if (line.contains('EXT-X-KEY')) {
            out.writeln(
                '${keyUriMatch.group(1)}${_keyUrl(resId, upstream)}${keyUriMatch.group(3)}');
          } else {
            out.writeln(
                '${keyUriMatch.group(1)}${_segUrl(upstream)}${keyUriMatch.group(3)}');
          }
        } else {
          out.writeln(line);
        }
        continue;
      }
      final upstream = playlistUri.resolve(line);
      if (line.contains('.m3u8')) {
        out.writeln(
            'http://127.0.0.1:$port/hls/$resId/index.m3u8?u=${Uri.encodeComponent(upstream.toString())}');
      } else {
        out.writeln(_segUrl(upstream));
      }
    }
    return out.toString();
  }

  String _keyUrl(String resId, Uri keyUri) =>
      'http://127.0.0.1:$port/hls/$resId/key?u=${Uri.encodeComponent(keyUri.toString())}';

  String _segUrl(Uri segUri) =>
      'http://127.0.0.1:$port/hls/x/seg?u=${Uri.encodeComponent(segUri.toString())}';

  // ---------------------------------------------------------------- key

  Future<void> _serveKey(HttpRequest req, String resId) async {
    final u = req.uri.queryParameters['u'];
    if (u == null) {
      _fail(req, 400, 'missing u');
      return;
    }
    final keyUri = Uri.parse(u);
    final keyId = keyUri.pathSegments.last;
    final cached = _keyCache[keyId];
    if (cached != null) {
      _serveBytes(req, cached);
      return;
    }

    try {
      final key = await _danceForKey(keyUri, keyId);
      _keyCache[keyId] = key;
      _serveBytes(req, key);
    } catch (e) {
      _fail(req, 502, 'key fetch failed: $e');
    }
  }

  Future<Uint8List> _danceForKey(Uri keyUri, String keyId) async {
    final token = _tokenProvider?.call();
    // 1. nonce
    final signsRes = await _upstream.get<Map<String, dynamic>>(
      '${keyUri.toString()}/signs',
      options: Options(
        headers: {'X-ND-AUTH': ?token},
        validateStatus: (s) => s != null && s < 400,
      ),
    );
    final nonce = signsRes.data?['nonce'] as String?;
    if (nonce == null || nonce.isEmpty) {
      throw StateError('signs endpoint returned no nonce');
    }
    // 2-3. sign + key blob
    final sign = KeyVault.deriveSign(nonce, keyId);
    final keyRes = await _upstream.get<Map<String, dynamic>>(
      keyUri.toString(),
      queryParameters: {'nonce': nonce, 'sign': sign},
      options: Options(
        headers: {'X-ND-AUTH': ?token},
        validateStatus: (s) => s != null && s < 400,
      ),
    );
    final blob = keyRes.data?['key'] as String?;
    if (blob == null || blob.isEmpty) {
      throw StateError('key endpoint returned no key');
    }
    // 4. ECB-decrypt to the raw 16 ASCII bytes.
    final key = KeyVault.decryptKey(blob, sign);
    if (key.length != 16) {
      throw StateError('unexpected key length ${key.length}');
    }
    return key;
  }

  Future<void> _serveBytes(HttpRequest req, List<int> bytes) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.binary;
    req.response.headers.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close().catchError((_) {});
  }

  // ---------------------------------------------------------------- segments

  Future<void> _serveStream(
      HttpRequest req, String? resId, String? target) async {
    if (target == null) {
      _fail(req, 400, 'missing u');
      return;
    }
    final uri = Uri.parse(target);
    final hostOk = uri.host.contains('ykt.cbern.com.cn') ||
        uri.host.contains('ykt.eduyun.cn') ||
        (_allowLoopbackUpstream && uri.host == '127.0.0.1');
    if (!hostOk) {
      _fail(req, 403, 'host not allowed: ${uri.host}');
      return;
    }
    final candidates = _failoverCandidates(uri, resId);
    final range = req.headers.value(HttpHeaders.rangeHeader);

    Object? lastErr;
    for (final candidate in candidates) {
      try {
        await _pipeUpstream(req, candidate, range);
        return;
      } catch (e) {
        lastErr = e;
      }
    }
    _fail(req, 502, 'upstream failed ($lastErr)');
  }

  /// r1→r2→r3 node failover (private CDN only).
  List<Uri> _failoverCandidates(Uri uri, String? resId) {
    if (!uri.host.contains(_privateNodePattern)) {
      return [uri];
    }
    final path = uri.path;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    final preferred = resId == null ? 1 : (_preferredNode[resId] ?? 1);
    final order = <int>[...{preferred, 1, 2, 3}];
    return [
      for (final n in order)
        Uri.parse('https://r$n-ndr-private.ykt.cbern.com.cn$path$query'),
    ];
  }

  Future<void> _pipeUpstream(HttpRequest req, Uri uri, String? range) async {
    final token = _tokenProvider?.call();
    final upstreamReq = await _httpClient.getUrl(uri)
      ..headers.set(HttpHeaders.userAgentHeader, 'huichuang_basic/1.0');
    if (token != null && token.isNotEmpty) {
      upstreamReq.headers.set('X-ND-AUTH', token);
    }
    if (range != null) {
      upstreamReq.headers.set(HttpHeaders.rangeHeader, range);
    }
    final upstreamRes = await upstreamReq.close();
    if (upstreamRes.statusCode >= 400) {
      await upstreamRes.drain<void>();
      throw StateError('upstream ${upstreamRes.statusCode}');
    }

    final res = req.response;
    res.statusCode = upstreamRes.statusCode;
    final len = upstreamRes.headers.value(HttpHeaders.contentLengthHeader);
    final lenVal = len == null ? null : int.tryParse(len);
    if (lenVal != null && lenVal >= 0) res.headers.contentLength = lenVal;
    final contentRange =
        upstreamRes.headers.value(HttpHeaders.contentRangeHeader);
    if (contentRange != null) {
      res.headers.set(HttpHeaders.contentRangeHeader, contentRange);
    }
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    await res.addStream(upstreamRes.cast<List<int>>());
    await res.close();
  }

  // ---------------------------------------------------------------- helpers

  Future<String> _fetchText(Uri uri) async {
    final token = _tokenProvider?.call();
    final res = await _upstream.get<String>(uri.toString(),
        options: Options(
          responseType: ResponseType.plain,
          headers: {'X-ND-AUTH': ?token},
          validateStatus: (s) => s != null && s < 400,
        ));
    return res.data ?? '';
  }

  int _nodeIndex(Uri uri) {
    final m = _nodePrefix.firstMatch(uri.toString());
    if (m == null) return 1;
    return int.parse(uri.host.substring(1, 2));
  }

  void _fail(HttpRequest req, int status, String message) {
    debugPrint('PROXY_FAIL $status ${req.uri.path} $message');
    try {
      final clean = message.replaceAll(RegExp(r'[\r\n]+'), ' ');
      req.response.statusCode = status;
      req.response.headers.set('x-proxy-error',
          clean.length > 170 ? clean.substring(0, 170) : clean);
      req.response.write(message);
      req.response.close().catchError((_) {});
    } catch (_) {}
  }
}
