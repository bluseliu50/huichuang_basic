/// Streaming download of platform files (textbook PDFs, lesson attachments)
/// plus the file-name/mime helpers the cross-platform export flow needs.
///
/// Downloads always go through the local StreamProxy URL, so auth injection
/// and r1→r2→r3 node failover come for free; this file itself is pure
/// dart:io on purpose — no Flutter imports, trivially unit-testable.
library;

import 'dart:io';

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
