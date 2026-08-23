import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../store/app_state.dart';
import '../../stream/proxy.dart';
import '../login/login_card.dart';
import '../pdf/pdf_reader_page.dart';
import '../player/player_page.dart';

/// Local catalog search (remote x-search is WAF-fenced against non-browser
/// clients — verified). Searches course materials, textbooks and the
/// currently loaded lesson list.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  String _query = '';
  List<String> _recent = [];
  bool _openingBook = false;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppController>();
    if (app.catalog.tagTree == null) {
      app.bootstrap();
    }
    if (app.catalog.textbooks == null) {
      app.catalog.loadTextbooks().catchError((_) {});
    }
  }

  void _submit(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    setState(() {
      _query = query;
      _recent = [query, ..._recent.where((r) => r != query)].take(8).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final materials = _query.isEmpty
        ? const <TeachingMaterial>[]
        : app.catalog.searchMaterials(_query);
    final textbooks = _query.isEmpty
        ? const <TeachingMaterial>[]
        : app.catalog.searchTextbooks(_query);
    final lessons = _query.isEmpty
        ? const <Lesson>[]
        : app.lessons
            .where((l) => l.title.toLowerCase().contains(_query.toLowerCase()))
            .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('搜索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SearchBar(
              controller: _controller,
              hintText: '搜索课程、教材、课时（本地目录）',
              leading: const Icon(Icons.search),
              trailing: [
                if (_query.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _controller.clear();
                      setState(() => _query = '');
                    },
                  ),
              ],
              onSubmitted: _submit,
            ),
          ),
          Expanded(
            child: _query.isEmpty
                ? _buildIdle(context)
                : ListView(
                    children: [
                      if (lessons.isNotEmpty) ...[
                        _header('本教材课时'),
                        for (final l in lessons)
                          ListTile(
                            leading: const Icon(Icons.play_circle_outline),
                            title: Text(l.title),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    PlayerPage(resId: l.id, title: l.title),
                              ),
                            ),
                          ),
                      ],
                      if (materials.isNotEmpty) ...[
                        _header('课程教材'),
                        for (final m in materials.take(20))
                          ListTile(
                            leading: const Icon(Icons.school_outlined),
                            title: Text(m.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              [m.tags['zxxnj'], m.tags['zxxxk']]
                                  .whereType<String>()
                                  .join(' · '),
                            ),
                            onTap: () {
                              app.openMaterial(m);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('已打开《${m.title}》')),
                              );
                            },
                          ),
                      ],
                      if (textbooks.isNotEmpty) ...[
                        _header('电子教材'),
                        for (final b in textbooks.take(20))
                          ListTile(
                            leading: const Icon(Icons.book_outlined),
                            title: Text(b.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: _openingBook
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : null,
                            onTap: () => _openTextbook(b),
                          ),
                      ],
                      if (materials.isEmpty &&
                          textbooks.isEmpty &&
                          lessons.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            children: [
                              Text('本地目录中没有找到「$_query」'),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: () => launchUrl(
                                  Uri.parse(
                                      'https://basic.smartedu.cn/search?keyword=${Uri.encodeComponent(_query)}'),
                                  mode: LaunchMode.externalApplication,
                                ),
                                child: const Text('在浏览器中打开官方搜索'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdle(BuildContext context) {
    if (_recent.isEmpty) {
      return Center(
        child: Text(
          '输入关键词搜索课程、教材与课时\n数据来自已缓存的平台目录',
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    return ListView(
      children: [
        _header('最近搜索'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in _recent)
                InputChip(
                  label: Text(r),
                  onPressed: () {
                    _controller.text = r;
                    _submit(r);
                  },
                  onDeleted: () => setState(() => _recent.remove(r)),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      );

  Future<void> _openTextbook(TeachingMaterial b) async {
    final auth = context.read<AuthController>();
    final proxy = context.read<StreamProxy>();
    final app = context.read<AppController>();
    final token = await auth.ensureValidToken();
    if (token == null) {
      if (mounted) showLoginCard(context);
      return;
    }
    if (!mounted) return;
    setState(() => _openingBook = true);
    try {
      final detail = await app.client.getTextbookDetail(b.id);
      final pdf = detail.related
          .where((r) => (r.format ?? '').toLowerCase() == 'pdf')
          .toList();
      final target = pdf.isNotEmpty
          ? pdf.first
          : (detail.related.isNotEmpty ? detail.related.first : null);
      if (target == null || target.storages.isEmpty) {
        throw StateError('该教材没有可打开的 PDF');
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PdfReaderPage(
            title: b.title,
            url: proxy.fileUrl(target.storages.first),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开教材失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _openingBook = false);
    }
  }
}
