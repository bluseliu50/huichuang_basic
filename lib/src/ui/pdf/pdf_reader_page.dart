import 'dart:async';
import 'dart:io' show File, Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../download/download.dart';
import '../export_file.dart';

/// PDF reader for textbook pages and 课件 PDFs. Download-first: the proxy
/// URL is fetched ONCE into the shared upstream-keyed cache, the viewer
/// opens the local file, and the AppBar export reuses the same bytes —
/// preview-then-export never downloads twice, and a previously opened
/// document re-opens instantly, offline. Remembers the last page per
/// document (keyed by the upstream URL, which survives proxy restarts
/// unlike the loopback port).
///
/// Desktop gets a slim button toolbar + keyboard navigation; phones keep
/// the slider bar.
///
/// Layout note: the page-turn bar deliberately lives INSIDE the body
/// column, not in [Scaffold.bottomNavigationBar]. On an Android 16
/// foldable (Pixel 9 Pro Fold) the bottomNavigationBar slot handed the
/// bar full-window-height constraints — it expanded over the whole page
/// and covered everything (blank reader, slider floating mid-screen).
/// In the column it gets a bounded, loose height everywhere.
class PdfReaderPage extends StatefulWidget {
  const PdfReaderPage({super.key, required this.title, required this.url});

  final String title;
  final Uri url;

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  final PdfViewerController _controller = PdfViewerController();
  int _pages = 0;
  int _page = 1;

  Timer? _saveDebounce;

  File? _local;
  int _received = 0;
  int? _total;
  Object? _prepError;
  bool _cancelled = false;

  static bool get _isPhone => Platform.isAndroid || Platform.isIOS;

  late final Uri _upstream =
      upstreamOf(widget.url) ?? widget.url;

  String get _key => 'hc_pdf_lastpage_${_upstream.hashCode}';

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
        _upstream,
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
      // The 取消 button pops the page itself; nothing to do when it already
      // went away.
    } catch (e) {
      if (mounted) setState(() => _prepError = e);
    }
  }

  Future<void> _savePage(int page) async {
    _saveDebounce = Timer(const Duration(seconds: 1), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, page);
    });
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The reader has no text input; a (possibly stale) IME inset must
    // never shrink the reading area.
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          // Only meaningful once the bytes are local — the button exports
          // the cache slot without touching the network.
          if (_local != null)
            IconButton(
              tooltip: '下载 PDF',
              icon: const Icon(Icons.download_outlined),
              onPressed: () => exportLocalFile(
                context,
                file: _local!,
                fileName: attachmentFileName(widget.title, 'pdf'),
                mimeType: mimeForFormat('pdf'),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _prepError != null
                ? _prepErrorView(context)
                : _local == null
                    ? _preparingView(context)
                    : _buildViewer(context),
          ),
          if (_pages > 0)
            SafeArea(top: false, child: _isPhone ? _phoneBar() : _desktopBar()),
        ],
      ),
    );
  }

  /// Shown while the document downloads into the cache (cache hits skip
  /// this entirely — the first frame already has the file).
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

  Widget _prepErrorView(BuildContext context) {
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

  Widget _buildViewer(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _jump(_page - 1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _jump(_page + 1),
        const SingleActivator(LogicalKeyboardKey.home): () => _jump(1),
        const SingleActivator(LogicalKeyboardKey.end): () => _jump(_pages),
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          // pdfrx 1.3.5: _updateLayout early-returns on height<=0 leaving
          // _layout null, but the same builder then dereferences _layout!
          // (pdf_viewer.dart:453) — one zero-height frame (window minimize
          // / restore, tiny window) crashes the page. Never hand pdfrx a
          // zero or non-finite viewport; the rebuild on the next sane
          // frame remounts the viewer.
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            if (w <= 0 || h <= 0 || !w.isFinite || !h.isFinite) {
              return const SizedBox.expand();
            }
            return PdfViewer(
              // Local cache file: network quirks (range-served page objects
              // arriving unreliably → silently blank pages) are gone, and
              // the same bytes feed the AppBar export.
              PdfDocumentRefFile(_local!.path),
              controller: _controller,
              params: PdfViewerParams(
                // Pre-render ±2.5 screens of neighbor pages so
                // fast page flips hit already-rendered pages
                // instead of waiting on the serialized render
                // queue (default 1.0 screen still shows blank
                // pages during fast scrolls on phones).
                errorBannerBuilder: (context, error, stack, ref) {
                  return Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'PDF 错误: $error',
                      style: const TextStyle(color: Colors.red),
                    ),
                  );
                },
                horizontalCacheExtent: 1.0,
                verticalCacheExtent: 2.5,
                loadingBannerBuilder: (context, done, total) => const Center(
                  child: CircularProgressIndicator(),
                ),
                // Desktop default: fit one whole page (fitZoom). The
                // pdfrx default (coverZoom) fits the page WIDTH, which
                // reads oversized on a tall window. Phones keep the
                // default — a portrait page fitted to height is tiny.
                sizeDelegateProvider: _isPhone
                    ? null
                    : PdfViewerSizeDelegateProviderLegacy(
                        calculateInitialZoom:
                            (
                              document,
                              controller,
                              fitZoom,
                              coverZoom,
                            ) => fitZoom,
                      ),
                onViewerReady: (document, controller) async {
                  setState(() => _pages = document.pages.length);
                  final prefs = await SharedPreferences.getInstance();
                  final saved = prefs.getInt(_key) ?? 1;
                  if (saved > 1 && saved <= document.pages.length) {
                    _goToPageSafe(controller, saved);
                  }
                },
                onPageChanged: (pageNumber) {
                  if (pageNumber != null) {
                    setState(() => _page = pageNumber);
                    _savePage(pageNumber);
                  }
                },
              ),
            );
          },
        ),
      ),
    );
  }

  /// Slim button toolbar for desktop: no fat slider, keyboard-friendly.
  Widget _desktopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: '第一页 (Home)',
            onPressed: () => _jump(1),
            icon: const Icon(Icons.first_page),
          ),
          Text('$_page / $_pages'),
          IconButton(
            tooltip: '最后一页 (End)',
            onPressed: () => _jump(_pages),
            icon: const Icon(Icons.last_page),
          ),
        ],
      ),
    );
  }

  /// Phone layout: slider for fast scrubbing across 100+ page textbooks.
  Widget _phoneBar() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          IconButton(
            tooltip: '第一页',
            icon: const Icon(Icons.first_page),
            onPressed: () => _jump(1),
          ),
          Expanded(
            child: Slider(
              value: _page.clamp(1, _pages).toDouble(),
              min: 1,
              max: _pages.toDouble(),
              divisions: _pages > 1 ? _pages - 1 : 1,
              label: '$_page',
              onChanged: (v) => _jump(v.round()),
            ),
          ),
          IconButton(
            tooltip: '最后一页',
            icon: const Icon(Icons.last_page),
            onPressed: () => _jump(_pages),
          ),
        ],
      ),
    );
  }

  void _jump(int page) {
    if (_pages == 0) return;
    final target = page.clamp(1, _pages);
    setState(() => _page = target);
    _goToPageSafe(_controller, target);
  }

  /// pdfrx's goToPage dereferences its page layout, which is null until the
  /// first layout pass finishes; dragging the slider in that window throws.
  /// The state already carries the target page, so dropping the jump is safe.
  void _goToPageSafe(PdfViewerController controller, int page) {
    try {
      controller.goToPage(pageNumber: page);
    } catch (_) {}
  }
}
