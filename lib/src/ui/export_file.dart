/// Cross-platform 下载导出: streams a proxy URL into the on-disk cache
/// with a progress dialog, then hands the bytes to `FilePicker.saveFile`,
/// which shows the platform's native save dialog and writes the file itself —
/// NSSavePanel (macOS), IFileSaveDialog (Windows), XDG portal (Linux),
/// SAF create-document (Android), UIDocumentPicker export (iOS).
///
/// One identical Dart path on every platform; the only platform branch is
/// the macOS entitlement opt-out (this app is not sandboxed, and
/// file_picker refuses save dialogs without the read-write user-selected
/// entitlement unless told to skip the check).
///
/// Downloads land in the shared cache keyed by the upstream URL, so
/// preview-then-export (or export-then-preview) transfers the bytes once.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../download/download.dart';
import 'login/login_card.dart';

bool _macosEntitlementsSkipped = false;

/// Extracts the upstream resource URL from a StreamProxy file URL
/// (`/file?u=<encoded upstream>`); the cache key must survive proxy
/// restarts, and the ported loopback URL does not.
Uri? upstreamOf(Uri proxyUrl) {
  final u = proxyUrl.queryParameters['u'];
  if (u == null || u.isEmpty) return null;
  return Uri.tryParse(u);
}

/// Downloads [proxyUrl] through the cache and exports it via the native
/// save dialog as [fileName].
///
/// Returns true when the file was written, false when the user canceled
/// (login, progress dialog or save dialog) — cancellations are silent.
/// Requires a logged-in account: private-CDN files 401 without X-ND-AUTH,
/// which the proxy injects from the AuthController token.
Future<bool> exportFile(
  BuildContext context, {
  required Uri proxyUrl,
  required String fileName,
  required String mimeType,
}) async {
  final token = await context.read<AuthController>().ensureValidToken();
  if (token == null) {
    if (context.mounted) showLoginCard(context);
    return false;
  }
  final upstream = upstreamOf(proxyUrl);
  if (upstream == null) {
    throw ArgumentError('proxyUrl must be a StreamProxy file URL: $proxyUrl');
  }
  if (!context.mounted) return false;

  // Drive the download from inside the dialog so progress and cancel live
  // with the UI that shows them.
  final cached = await showDialog<File>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ExportDialog(
      url: proxyUrl,
      upstream: upstream,
      fileName: fileName,
    ),
  );
  if (cached == null) return false;
  if (!context.mounted) return false; // bytes stay cached for the next open
  return exportLocalFile(
    context,
    file: cached,
    fileName: fileName,
    mimeType: mimeType,
  );
}

/// Save-dialog half only: exports an already-downloaded local [file] — no
/// network, no login (the bytes are already on disk). The reader uses this
/// so preview-then-export never downloads twice.
Future<bool> exportLocalFile(
  BuildContext context, {
  required File file,
  required String fileName,
  required String mimeType,
}) async {
  try {
    if (!_macosEntitlementsSkipped) {
      _macosEntitlementsSkipped = true;
      await FilePicker.skipEntitlementsChecks();
    }
    final saved = await FilePicker.saveFile(
      fileName: fileName,
      bytes: await file.readAsBytes(),
      mimeType: mimeType,
      dialogTitle: '保存 $fileName',
    );
    if (saved == null) return false;
    if (context.mounted) {
      final where = saved.scheme == 'file' ? '\n${saved.toFilePath()}' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存 $fileName$where')),
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
    return false;
  }
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({
    required this.url,
    required this.upstream,
    required this.fileName,
  });

  final Uri url;
  final Uri upstream;
  final String fileName;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  int _received = 0;
  int? _total;
  Object? _error;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final file = await cachedDownload(
        widget.url,
        widget.upstream,
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              _received = received;
              _total = total;
            });
          }
        },
        cancelled: () => _cancelled,
      );
      if (mounted) Navigator.of(context).pop(file);
    } on DownloadCancelled {
      // silent — the user pressed 取消
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  static String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final known = _total != null && _total! > 0;
    return AlertDialog(
      title: const Text('下载'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.fileName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Text(
              '下载失败：$_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            )
          else ...[
            LinearProgressIndicator(value: known ? _received / _total! : null),
            const SizedBox(height: 8),
            Text(
              known
                  ? '${_mb(_received)} / ${_mb(_total!)} MB'
                  : '${_mb(_received)} MB',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        if (_error != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          )
        else
          TextButton(
            onPressed: () {
              _cancelled = true;
              Navigator.of(context).pop();
            },
            child: const Text('取消'),
          ),
      ],
    );
  }
}
