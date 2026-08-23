/// Live end-to-end check of the streaming proxy against the real platform.
///
/// Usage:
///   HC_TOKEN=... dart run tool/live_check.dart [resId]
///
/// Never commits credentials — token comes from the environment.
library;

import 'dart:convert';
import 'dart:io';

import 'package:huichuang_basic/src/api/client.dart';
import 'package:huichuang_basic/src/stream/proxy.dart';

Future<void> main(List<String> args) async {
  final token = Platform.environment['HC_TOKEN'];
  if (token == null || token.isEmpty) {
    stderr.writeln('HC_TOKEN env var required');
    exit(2);
  }
  final resId = args.isNotEmpty
      ? args.first
      : '57d37f35-8b72-4c7d-b76d-948422b61b28'; // 大青树下的小学

  final client = SmarteduClient();
  final detail = await client.getResourceDetail(resId);
  final video = detail.video;
  if (video == null || video.storages.isEmpty) {
    stderr.writeln('no m3u8 storages found for $resId');
    exit(1);
  }
  stdout.writeln('lesson: ${detail.title}');
  stdout.writeln('mirrors: ${video.storages.length}');

  final proxy = StreamProxy(tokenProvider: () => token);
  await proxy.start();
  proxy.register(resId, video.storages);
  stdout.writeln('proxy listening on 127.0.0.1:${proxy.port}');

  final http = HttpClient();

  // 1. Playlist through proxy.
  final plRes = await (await http.getUrl(proxy.playlistUrl(resId))).close();
  final playlist = await plRes.transform(utf8.decoder).join();
  if (plRes.statusCode != 200 || !playlist.startsWith('#EXTM3U')) {
    stderr.writeln('playlist FAILED ${plRes.statusCode}: ${playlist.substring(0, playlist.length > 200 ? 200 : playlist.length)}');
    exit(1);
  }
  final segCount = RegExp(r'^\S+\.ts$', multiLine: true).allMatches(playlist).length;
  stdout.writeln('playlist OK ($segCount segments, ${playlist.length} bytes)');

  // 2. Key through proxy (nonce/sign dance + ECB decrypt).
  final keyUrl = RegExp(r'URI="([^"]+)"').firstMatch(playlist)!.group(1)!;
  final keyRes = await (await http.getUrl(Uri.parse(keyUrl))).close();
  final keyBytes =
      await keyRes.fold<List<int>>(<int>[], (a, d) => a..addAll(d));
  if (keyRes.statusCode != 200 || keyBytes.length != 16) {
    stderr.writeln('key FAILED ${keyRes.statusCode} len=${keyBytes.length}');
    exit(1);
  }
  stdout.writeln(
      'key OK (16 bytes, ascii=${keyBytes.every((b) => b >= 0x20 && b < 0x7f)})');

  // 3. First segment through proxy (auth-injected, node failover).
  final segUrl = RegExp(r'^(http://127\.0\.0\.1:\d+/hls/x/seg\?u=\S+)$',
          multiLine: true)
      .firstMatch(playlist)!
      .group(1)!;
  final segRes = await (await http.getUrl(Uri.parse(segUrl))).close();
  final segBytes =
      await segRes.fold<List<int>>(<int>[], (a, d) => a..addAll(d));
  if (segRes.statusCode != 200 || segBytes.length < 100000) {
    stderr.writeln(
        'segment FAILED ${segRes.statusCode} len=${segBytes.length}');
    exit(1);
  }
  stdout.writeln(
      'segment OK (${segBytes.length} bytes, ts sync byte=0x${segBytes[4].toRadixString(16)})');

  // 4. Textbook PDF path through the same proxy.
  final pdfRes0 = await (await http.getUrl(Uri.parse(
          'https://s-file-1.ykt.cbern.com.cn/zxx/ndrv2/resources/tch_material/details/bdc00134-465d-454b-a541-dcd0cec4d86e.json')))
      .close();
  final pdfJson =
      jsonDecode(await pdfRes0.transform(utf8.decoder).join()) as Map<String, dynamic>;
  final pdfStorages = <Uri>[];
  for (final item
      in ((pdfJson['ti_items'] as List?) ?? []).cast<Map>()) {
    for (final s in (item['ti_storages'] as List?) ?? const []) {
      final u = s as String?;
      if (u != null && u.endsWith('.pdf')) pdfStorages.add(Uri.parse(u));
    }
  }
  if (pdfStorages.isEmpty) {
    stdout.writeln('pdf: no .pdf storages (skipping)');
  } else {
    final pdfUrl = proxy.fileUrl(pdfStorages.first);
    final pdfReq = await http.getUrl(pdfUrl);
    pdfReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    final pdfRes = await pdfReq.close();
    final head =
        await pdfRes.fold<List<int>>(<int>[], (a, d) => a..addAll(d));
    final magic = String.fromCharCodes(head.take(5));
    stdout.writeln(
        'pdf OK (${pdfRes.statusCode}, range ${head.length} bytes, magic=$magic)');
  }

  await proxy.stop();
  stdout.writeln('LIVE CHECK PASSED');
  exit(0);
}
