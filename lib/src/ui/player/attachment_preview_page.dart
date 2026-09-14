import 'dart:io';

import 'package:flutter/material.dart';

import '../../download/download.dart';
import '../export_file.dart';

/// Preview page for non-PDF lesson attachments (教学设计 docx, 课件 pptx,
/// 学习任务单, …) — the PDF kind previews in [PdfReaderPage] instead.
///
/// Download-first into the shared upstream-keyed cache, then a document
/// card offering 导出保存 (native save dialog reusing the cached bytes)
/// and, on desktop, 用系统程序打开 via a properly-named copy.
class AttachmentPreviewPage extends StatefulWidget {
  const AttachmentPreviewPage({
    super.key,
    required this.title,
    required this.url,
    required this.format,
  });

  final String title;

  /// StreamProxy file URL of the attachment.
  final Uri url;
  final String? format;

  @override
  State<AttachmentPreviewPage> createState() => _AttachmentPreviewPageState();
}

class _AttachmentPreviewPageState extends State<AttachmentPreviewPage> {
  File? _local;
  int _received = 0;
  int? _total;
  Object? _prepError;
  bool _cancelled = false;

  static bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    _cancelled = false;
    try {
      final file = await cachedDownload(
        widget.url,
        upstreamOf(widget.url)!,
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
      if (mounted) setState(() => _local = file);
    } on DownloadCancelled {
      // The 取消 button pops the page itself.
    } catch (e) {
      if (mounted) setState(() => _prepError = e);
    }
  }

  Future<void> _export() async {
    await exportLocalFile(
      context,
      file: _local!,
      fileName: attachmentFileName(widget.title, widget.format),
      mimeType: mimeForFormat(widget.format),
    );
  }

  Future<void> _openWithSystem() async {
    try {
      // The cache slot's hash name carries no extension; system openers
      // sniff by extension, so hand them a properly-named local copy.
      final dest = File(
        '${Directory.systemTemp.path}/${attachmentFileName(widget.title, widget.format)}',
      );
      await _local!.copy(dest.path);
      final opener = Platform.isMacOS
          ? 'open'
          : Platform.isLinux
          ? 'xdg-open'
          : 'cmd';
      final args =
          Platform.isWindows ? ['/c', 'start', '', dest.path] : [dest.path];
      await Process.run(opener, args);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开失败：$e')));
      }
    }
  }

  IconData get _icon => switch ((widget.format ?? '').toLowerCase()) {
    'ppt' || 'pptx' => Icons.slideshow_outlined,
    'doc' || 'docx' => Icons.description_outlined,
    'txt' => Icons.notes_outlined,
    'jpg' || 'jpeg' || 'png' => Icons.image_outlined,
    _ => Icons.insert_drive_file_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _prepError != null
          ? _errorView(context)
          : _local == null
          ? _preparingView(context)
          : _documentCard(context),
    );
  }

  Widget _preparingView(BuildContext context) {
    final known = _total != null && _total! > 0;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 240,
            child: LinearProgressIndicator(
              value: known ? _received / _total! : null,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            known
                ? '${(_received / 1048576).toStringAsFixed(1)} / ${(_total! / 1048576).toStringAsFixed(1)} MB'
                : '正在下载…',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              _cancelled = true;
              Navigator.of(context).maybePop();
            },
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _errorView(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('打开失败：$_prepError'),
          const SizedBox(height: 4),
          Text(
            '请确认已登录、网络可用后重试',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () {
              setState(() => _prepError = null);
              _prepare();
            },
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _documentCard(BuildContext context) {
    final size = _local!.lengthSync();
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 72, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              '${(widget.format ?? '文件').toUpperCase()} · ${(size / 1048576).toStringAsFixed(1)} MB',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.outline,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _export,
              icon: const Icon(Icons.download_outlined),
              label: const Text('导出保存'),
            ),
            if (_isDesktop) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _openWithSystem,
                icon: const Icon(Icons.open_in_new),
                label: const Text('用系统程序打开'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
