import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../store/app_state.dart';
import '../../stream/proxy.dart';
import '../login/login_card.dart';
import 'pdf_reader_page.dart';

/// 电子教材 browser: cascading tag selector + book grid + PDF reader.
class TextbooksPage extends StatefulWidget {
  const TextbooksPage({super.key});

  @override
  State<TextbooksPage> createState() => _TextbooksPageState();
}

class _TextbooksPageState extends State<TextbooksPage> {
  String? _stageId;
  String? _subjectId;
  String? _editionId;
  String? _gradeId;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await context.read<AppController>().catalog.loadTextbooks();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final tree = app.catalog.textbookTagTree;
    final books = app.catalog.textbooks ?? const <TeachingMaterial>[];

    if (_loading && tree == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('教材')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (tree == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('教材')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('教材目录加载失败'),
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    // The tch_material tree nests real levels under a container root
    // (电子教材) — descend to the first zxxxd level.
    var stages = tree.roots;
    while (stages.isNotEmpty &&
        stages.first.dimensionId != 'zxxxd' &&
        stages.first.children.isNotEmpty) {
      stages = stages.first.children;
    }
    if (stages.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('教材')),
        body: const Center(child: Text('教材目录为空')),
      );
    }
    _stageId ??= stages.first.id;
    final subjects = _childrenOf(stages, _stageId);
    _subjectId = subjects.any((s) => s.id == _subjectId)
        ? _subjectId
        : (subjects.isNotEmpty ? subjects.first.id : null);
    final editions = _childrenOf(subjects, _subjectId);
    _editionId = editions.any((e) => e.id == _editionId)
        ? _editionId
        : (editions.isNotEmpty ? editions.first.id : null);
    final grades = _childrenOf(editions, _editionId);
    _gradeId = grades.any((g) => g.id == _gradeId)
        ? _gradeId
        : (grades.isNotEmpty ? grades.first.id : null);

    final filtered = books.where((b) {
      if (_stageId != null && b.tagIds['zxxxd'] != _stageId) return false;
      if (_subjectId != null && b.tagIds['zxxxk'] != _subjectId) return false;
      if (_editionId != null && b.tagIds['zxxbb'] != _editionId) return false;
      if (_gradeId != null && b.tagIds['zxxnj'] != _gradeId) return false;
      return true;
    }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('教材')),
      body: Column(
        children: [
          _pickerRow('学段', stages, _stageId, (id) => setState(() {
                _stageId = id;
                _subjectId = null;
                _editionId = null;
                _gradeId = null;
              })),
          if (subjects.isNotEmpty)
            _pickerRow('学科', subjects, _subjectId,
                (id) => setState(() {
                      _subjectId = id;
                      _editionId = null;
                      _gradeId = null;
                    })),
          if (editions.isNotEmpty)
            _pickerRow('版本', editions, _editionId,
                (id) => setState(() {
                      _editionId = id;
                      _gradeId = null;
                    })),
          if (grades.isNotEmpty)
            _pickerRow('年级', grades, _gradeId, (id) => setState(() => _gradeId = id)),
          const Divider(height: 1),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('暂无教材'))
                : GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.62,
                    ),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) =>
                        _BookCard(book: filtered[i]),
                  ),
          ),
        ],
      ),
    );
  }

  List<TagNode> _childrenOf(List<TagNode> level, String? id) {
    if (id == null) return const [];
    for (final n in level) {
      if (n.id == id) return n.children;
    }
    return const [];
  }

  Widget _pickerRow(String label, List<TagNode> options, String? selected,
      void Function(String?) onPick) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Text(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                    fontSize: 13)),
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              itemCount: options.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final o = options[i];
                return ChoiceChip(
                  label: Text(o.name),
                  selected: selected == o.id,
                  onSelected: (on) => onPick(on ? o.id : null),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({required this.book});

  final TeachingMaterial book;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: InkWell(
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Builder(builder: (context) {
                    final cover = context
                        .watch<AppController>()
                        .textbookCoverOf(book.id);
                    if (cover == null) {
                      return Container(
                        width: double.infinity,
                        color: Theme.of(context).colorScheme.primaryContainer,
                        child: Icon(Icons.menu_book_outlined,
                            size: 40,
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer),
                      );
                    }
                    return CachedNetworkImage(
                      imageUrl: cover.toString(),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorWidget: (_, _, _) => Container(
                        width: double.infinity,
                        color:
                            Theme.of(context).colorScheme.primaryContainer,
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                book.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final auth = context.read<AuthController>();
    final app = context.read<AppController>();
    final proxy = context.read<StreamProxy>();
    final token = await auth.ensureValidToken();
    if (token == null) {
      if (context.mounted) showLoginCard(context);
      return;
    }
    try {
      final detail = await app.client.getTextbookDetail(book.id);
      final pdf = detail.related
          .where((r) => (r.format ?? '').toLowerCase() == 'pdf')
          .toList();
      final target = pdf.isNotEmpty
          ? pdf.first
          : (detail.related.isNotEmpty ? detail.related.first : null);
      if (target == null || target.storages.isEmpty) {
        throw StateError('该教材没有可打开的 PDF');
      }
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PdfReaderPage(
            title: book.title,
            url: proxy.fileUrl(target.storages.first),
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开教材失败：$e')),
        );
      }
    }
  }
}
