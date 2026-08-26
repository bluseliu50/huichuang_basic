import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PDF reader for textbook pages and 课件 PDFs, streamed through the
/// local auth-injecting proxy. Remembers the last page per document.
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
  bool _error = false;
  Timer? _saveDebounce;

  String get _key => 'hc_pdf_lastpage_${widget.url.hashCode}';

  Future<void> _savePage(int page) async {
    _saveDebounce?.cancel();
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_pages > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: Text('$_page / $_pages')),
            ),
        ],
      ),
      body: _error
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('打开失败，请确认已登录后重试'),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: () => setState(() => _error = false),
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          : LayoutBuilder(
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
                  PdfDocumentRefUri(
                    widget.url,
                    preferRangeAccess: true,
                  ),
                  controller: _controller,
                  params: PdfViewerParams(
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
      bottomNavigationBar: _pages == 0
          ? null
          : Padding(
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
            ),
    );
  }

  void _jump(int page) {
    if (_pages == 0) return;
    final clamped = page.clamp(1, _pages);
    setState(() => _page = clamped);
    _savePage(clamped);
    _goToPageSafe(_controller, clamped);
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
