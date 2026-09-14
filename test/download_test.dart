import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huichuang_basic/src/download/download.dart';

void main() {
  group('sanitizeFileName', () {
    test('strips characters Windows forbids', () {
      expect(sanitizeFileName('a/b\\c:d*e?f"g<h>i|j'), 'a b c d e f g h i j');
    });

    test('strips control characters and collapses whitespace', () {
      expect(sanitizeFileName('教\u0000材\t\r\n课  件'), '教 材 课 件');
    });

    test('drops trailing dots and spaces', () {
      expect(sanitizeFileName('教材.'), '教材');
      expect(sanitizeFileName('教材 . '), '教材');
    });

    test('falls back when nothing is left', () {
      expect(sanitizeFileName('///'), '未命名');
      expect(sanitizeFileName('  '), '未命名');
    });

    test('keeps ordinary titles untouched', () {
      const name = '义务教育教科书·道德与法治一年级上册';
      expect(sanitizeFileName(name), name);
    });
  });

  group('attachmentFileName', () {
    test('appends the format extension', () {
      expect(attachmentFileName('第一课 教学设计', 'docx'), '第一课 教学设计.docx');
    });

    test('does not double an extension already in the title', () {
      expect(attachmentFileName('课件.PDF', 'pdf'), '课件.PDF');
    });

    test('sanitizes the title', () {
      expect(attachmentFileName('a/b 课件', 'pdf'), 'a b 课件.pdf');
    });

    test('no format keeps the title as-is', () {
      expect(attachmentFileName('未知资源', null), '未知资源');
      expect(attachmentFileName('未知资源', '.weird'), '未知资源.weird');
    });
  });

  group('mimeForFormat', () {
    test('maps known formats case-insensitively', () {
      expect(mimeForFormat('PDF'), 'application/pdf');
      expect(mimeForFormat('docx'), startsWith('application/vnd.openxml'));
      expect(mimeForFormat('ppt'), 'application/vnd.ms-powerpoint');
      expect(mimeForFormat(null), 'application/octet-stream');
      expect(mimeForFormat('xyz'), 'application/octet-stream');
    });
  });

  group('downloadToFile', () {
    late HttpServer server;
    late Directory tmp;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      tmp = await Directory.systemTemp.createTemp('hc_download_test_');
    });

    tearDown(() async {
      await server.close(force: true);
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    void serve(List<int> bytes, {bool withLength = true, int status = 200}) {
      server.listen((req) async {
        req.response.statusCode = status;
        if (withLength) req.response.contentLength = bytes.length;
        // Write in two chunks with a flush between so the progress callback
        // fires more than once even for small payloads.
        final mid = bytes.length ~/ 2;
        req.response.add(bytes.sublist(0, mid));
        await req.response.flush();
        req.response.add(bytes.sublist(mid));
        await req.response.close();
      });
    }

    Uri url() => Uri.parse('http://127.0.0.1:${server.port}/file');

    test('writes the bytes and reports monotonic progress', () async {
      final payload = List<int>.generate(64 * 1024, (i) => i & 0xFF);
      serve(payload);
      final dest = File('${tmp.path}/out.bin');
      final progress = <(int, int?)>[];

      final file = await downloadToFile(url(), dest,
          onProgress: (received, total) => progress.add((received, total)));

      expect(file.path, dest.path);
      expect(await dest.readAsBytes(), payload);
      expect(progress, isNotEmpty);
      expect(progress.last, (payload.length, payload.length));
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i].$1, greaterThan(progress[i - 1].$1));
      }
    });

    test('reports a null total when content-length is absent', () async {
      serve(List.filled(1024, 7), withLength: false);
      final seen = <(int, int?)>[];
      await downloadToFile(url(), File('${tmp.path}/nolen.bin'),
          onProgress: (r, t) => seen.add((r, t)));
      expect(seen.last, (1024, null));
    });

    test('throws on a non-200 status and leaves no partial file', () async {
      serve(const [], status: 404);
      final dest = File('${tmp.path}/gone.bin');
      await expectLater(
        downloadToFile(url(), dest),
        throwsA(isA<HttpException>()),
      );
      expect(dest.existsSync(), isFalse);
    });

    test('cancel mid-transfer deletes the partial file', () async {
      // 64 × 4 KiB chunks with a pause between writes: forces the client
      // to surface many read events so the cancel flag lands mid-stream.
      const chunkSize = 4 * 1024;
      const chunks = 64;
      server.listen((req) async {
        req.response.statusCode = 200;
        req.response.contentLength = chunkSize * chunks;
        final chunk = List<int>.filled(chunkSize, 1);
        for (var i = 0; i < chunks; i++) {
          req.response.add(chunk);
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        await req.response.close();
      });
      final dest = File('${tmp.path}/partial.bin');
      var cancelled = false;

      await expectLater(
        downloadToFile(
          url(),
          dest,
          onProgress: (received, total) {
            // Flip after the first reported chunk.
            if (received > 0) cancelled = true;
          },
          cancelled: () => cancelled,
        ),
        throwsA(isA<DownloadCancelled>()),
      );
      expect(dest.existsSync(), isFalse);
    });
  });
}
