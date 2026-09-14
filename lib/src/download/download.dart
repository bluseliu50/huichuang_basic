/// Streaming download of platform files (textbook PDFs, lesson attachments)
/// with a per-upstream-URL disk cache, plus the file-name/mime helpers the
/// cross-platform export flow needs.
///
/// Downloads always go through the local StreamProxy URL, so auth injection
/// and r1→r2→r3 node failover come for free; this file itself is pure
/// dart:io on purpose — no Flutter imports, trivially unit-testable.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Thrown by [downloadToFile] when [cancelled] flips mid-transfer.
class DownloadCancelled implements Exception {
  const DownloadCancelled();

  @override
  String toString() => 'DownloadCancelled';
}

/// Streams [url] into [dest], reporting `(received, total)` via [onProgress]
/// after every chunk. [total] is null when the server sends no content-length.
///
/// A non-200 response throws [HttpException]. On cancel or error the partial
/// file is deleted and the error rethrown, so [dest] only ever exists as a
/// complete download.
Future<File> downloadToFile(
  Uri url,
  File dest, {
  void Function(int received, int? total)? onProgress,
  bool Function()? cancelled,
  HttpClient? client,
}) async {
  final own = client == null;
  final http = client ?? HttpClient();
  try {
    final res = await (await http.getUrl(url)).close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('HTTP ${res.statusCode}', uri: url);
    }
    final total = res.contentLength < 0 ? null : res.contentLength;
    final sink = dest.openWrite();
    var received = 0;
    try {
      await for (final chunk in res) {
        if (cancelled?.call() ?? false) throw const DownloadCancelled();
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      await sink.close().catchError((_) => sink);
      try {
        await dest.delete();
      } catch (_) {}
      rethrow;
    }
    return dest;
  } finally {
    if (own) http.close(force: true);
  }
}

// ---------------------------------------------------------------- helpers

/// Characters Windows forbids in file names, plus C0 control chars. Slash
/// variants map to a space so "A/B" degrades to "A B" instead of gluing.
final _illegalChars = RegExp(r'[/\\:*?"<>|\x00-\x1F]');

/// Makes [name] safe to use as a file name on every platform: strips illegal
/// characters, collapses whitespace, drops trailing dots/spaces (Windows).
/// An empty result falls back to 未命名.
String sanitizeFileName(String name) {
  final cleaned = name
      .replaceAll(_illegalChars, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '')
      .trim();
  return cleaned.isEmpty ? '未命名' : cleaned;
}

/// Suggested export file name for a platform resource: the sanitized [title]
/// plus the resource's [format] extension, unless the title already ends
/// with it (case-insensitive).
String attachmentFileName(String title, String? format) {
  final ext =
      (format ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final name = sanitizeFileName(title);
  if (ext.isEmpty || name.toLowerCase().endsWith('.$ext')) return name;
  return '$name.$ext';
}

/// MIME type handed to the native save dialogs (drives the Android
/// create-document type filter; cosmetic elsewhere).
String mimeForFormat(String? format) =>
    switch ((format ?? '').toLowerCase()) {
      'pdf' => 'application/pdf',
      'doc' => 'application/msword',
      'docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'ppt' => 'application/vnd.ms-powerpoint',
      'pptx' =>
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt' => 'text/plain',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'mp4' => 'video/mp4',
      _ => 'application/octet-stream',
    };

// ---------------------------------------------------------------- cache

/// Cache root lives under the OS temp dir, so the OS reclaims it on
/// reboot / under disk pressure — no eviction code to maintain.
Directory get _cacheRoot =>
    Directory('${Directory.systemTemp.path}/hc_file_cache');

/// Stable cache slot for an upstream resource URL. Keyed by the UPSTREAM
/// url, never the proxy url: the proxy's port changes every run, the
/// upstream storage url does not.
File cacheSlotFor(Uri upstream) => File(
    '${_cacheRoot.path}/${sha1.convert(utf8.encode(upstream.toString()))}');

/// Downloads [proxyUrl] once into the cache slot of [upstream] and returns
/// the slot. A cached slot short-circuits the network entirely; concurrent
/// calls for the same key share one transfer. A slot only ever appears
/// complete: downloads land in a unique temp file first and are renamed
/// into place.
Future<File> cachedDownload(
  Uri proxyUrl,
  Uri upstream, {
  void Function(int received, int? total)? onProgress,
  bool Function()? cancelled,
}) async {
  final slot = cacheSlotFor(upstream);
  if (slot.existsSync()) return slot;
  final running = _inflight[slot.path];
  if (running != null) return running;
  final future = _downloadToSlot(proxyUrl, slot,
      onProgress: onProgress, cancelled: cancelled);
  _inflight[slot.path] = future;
  try {
    return await future;
  } finally {
    _inflight.remove(slot.path);
  }
}

final _inflight = <String, Future<File>>{};

Future<File> _downloadToSlot(
  Uri proxyUrl,
  File slot, {
  void Function(int received, int? total)? onProgress,
  bool Function()? cancelled,
}) async {
  // Sync on purpose: under FakeAsync (widget tests) async dart:io futures
  // never complete; the cache-miss path must still fail fast into the
  // reader's error view.
  if (!_cacheRoot.existsSync()) _cacheRoot.createSync(recursive: true);
  final tmp =
      File('${slot.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
  final done = await downloadToFile(proxyUrl, tmp,
      onProgress: onProgress, cancelled: cancelled);
  try {
    return await done.rename(slot.path);
  } on FileSystemException {
    // POSIX rename overwrites the destination silently; this branch is
    // Windows refusing to clobber an existing slot — another writer won
    // the race with the same content.
    try {
      await done.delete();
    } catch (_) {}
    return slot;
  }
}
