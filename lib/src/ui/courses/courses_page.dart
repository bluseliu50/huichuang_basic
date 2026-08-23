import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../store/app_state.dart';
import '../player/player_page.dart';

class CoursesPage extends StatelessWidget {
  const CoursesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('课程教学'),
        actions: [
          TextButton.icon(
            onPressed: () => showTextbookPicker(context),
            icon: const Icon(Icons.tune, size: 18),
            label: Text(
              _gradeEditionLabel(app) ?? '年级与版本',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: app.catalogPhase == LoadPhase.loading
          ? const Center(child: CircularProgressIndicator())
          : app.catalogPhase == LoadPhase.error
              ? _ErrorView(
                  message: '目录加载失败，请检查网络后重试',
                  onRetry: () => app.retryCatalog(),
                )
              : Column(
                  children: [
                    const _SubjectBar(),
                    const Divider(height: 1),
                    const Expanded(child: _BrowserBody()),
                  ],
                ),
    );
  }
}

/// "一年级 · 统编版"-style label for the app-bar filter button.
String? _gradeEditionLabel(AppController app) {
  final tree = app.catalog.tagTree;
  String? name(String? id) {
    if (tree == null || id == null) return null;
    String? hit;
    void walk(List<TagNode> level) {
      for (final n in level) {
        if (n.id == id) hit = n.name;
        walk(n.children);
      }
    }
    walk(tree.roots);
    return hit;
  }

  final parts = [name(app.selection.gradeId), name(app.selection.editionId)]
      .whereType<String>()
      .toList();
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Prominent subject switcher of the current stage; grade & edition are
/// adjusted through the app-bar filter button / cascading dialog.
class _SubjectBar extends StatelessWidget {
  const _SubjectBar();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final tree = app.catalog.tagTree;
    if (tree == null || tree.roots.isEmpty) return const SizedBox.shrink();
    final sel = app.selection;

    TagNode? stage;
    for (final n in tree.roots) {
      if (n.id == sel.stageId) stage = n;
    }
    stage ??= tree.roots.first;
    final stageNode = stage;

    // Dedup by subject name, keeping each subject's first parent grade.
    final seen = <String>{};
    final subjects = <(String, TagNode)>[
      for (final g in stage.children)
        for (final s in g.children)
          if (seen.add(s.name)) (g.id, s),
    ];

    return SizedBox(
      height: 60,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Text('学科',
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.outline)),
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              itemCount: subjects.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final (gradeId, s) = subjects[i];
                return ChoiceChip(
                  label: Text(s.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  selected: sel.subjectId == s.id,
                  onSelected: (on) {
                    if (!on) return;
                    final opened = app.selectSubject(
                      stageId: stageNode.id,
                      subjectId: s.id,
                      fallbackGradeId: gradeId,
                    );
                    if (!opened) showTextbookPicker(context);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

void showTextbookPicker(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (_) => const _TextbookPickerDialog(),
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off,
              size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(message),
          const SizedBox(height: 16),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _BrowserBody extends StatefulWidget {
  const _BrowserBody();

  @override
  State<_BrowserBody> createState() => _BrowserBodyState();
}

class _BrowserBodyState extends State<_BrowserBody> {
  String? _selectedChapterId;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    if (app.contentPhase == LoadPhase.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (app.chapters.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined,
                size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            const Text('选择教材后这里会显示课程目录'),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => showTextbookPicker(context),
              child: const Text('选择教材'),
            ),
          ],
        ),
      );
    }

    final selected = _findChapter(app.chapters, _selectedChapterId) ??
        app.chapters.first;
    final selectedLessons = app.lessonsFor(selected);
    final wide = MediaQuery.sizeOf(context).width >= 1000;

    if (!wide) {
      // Mobile: chapters as expandable tiles with inline lessons.
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        itemCount: app.chapters.length,
        itemBuilder: (context, i) => _ChapterTile(
          node: app.chapters[i],
          app: app,
          selectedId: selected.id,
          onSelect: (id) => setState(() => _selectedChapterId = id),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 300,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            itemCount: app.chapters.length,
            itemBuilder: (context, i) => _ChapterTile(
              node: app.chapters[i],
              app: app,
              selectedId: selected.id,
              onSelect: (id) => setState(() => _selectedChapterId = id),
              dense: true,
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: _LessonPane(chapter: selected, lessons: selectedLessons)),
      ],
    );
  }

  ChapterNode? _findChapter(List<ChapterNode> nodes, String? id) {
    if (id == null) return null;
    for (final n in nodes) {
      if (n.id == id) return n;
      final hit = _findChapter(n.children ?? const [], id);
      if (hit != null) return hit;
    }
    return null;
  }
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    required this.node,
    required this.app,
    required this.selectedId,
    required this.onSelect,
    this.dense = false,
    this.depth = 0,
  });

  final ChapterNode node;
  final AppController app;
  final String selectedId;
  final void Function(String id) onSelect;
  final bool dense;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final lessons = app.lessonsFor(node);
    final hasChildren = node.children?.isNotEmpty == true;
    final selected = selectedId == node.id;

    if (!hasChildren) {
      return Padding(
        padding: EdgeInsets.only(left: 12.0 * depth),
        child: ListTile(
          dense: true,
          selected: selected,
          title: Text(node.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: lessons.isEmpty ? null : Text('${lessons.length}'),
          onTap: () => onSelect(node.id),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(left: 8.0 * depth),
      child: ExpansionTile(
        initiallyExpanded: depth == 0,
        dense: dense,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(node.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: dense || lessons.isEmpty ? null : Text('${lessons.length} 课'),
        onExpansionChanged: (_) => onSelect(node.id),
        children: [
          for (final l in lessons)
            _LessonRow(lesson: l),
          for (final c in node.children!)
            _ChapterTile(
              node: c,
              app: app,
              selectedId: selectedId,
              onSelect: onSelect,
              dense: dense,
              depth: depth + 1,
            ),
        ],
      ),
    );
  }
}

class _LessonRow extends StatelessWidget {
  const _LessonRow({required this.lesson});

  final Lesson lesson;

  @override
  Widget build(BuildContext context) {
    final entry = context.read<AppController>().watchEntryOf(lesson.id);
    return Padding(
      padding: const EdgeInsets.only(left: 26),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(
          lesson.isCoursePackage
              ? Icons.play_circle_outline
              : Icons.description_outlined,
          size: 18,
          color: lesson.isCoursePackage
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outline,
        ),
        title: Text(lesson.title,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
        trailing: entry == null ? null : const Icon(Icons.history, size: 14),
        onTap: () => _open(context),
      ),
    );
  }

  void _open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(resId: lesson.id, title: lesson.title),
      ),
    );
  }
}

/// Lesson cards of the selected chapter with lazily fetched covers.
class _LessonPane extends StatelessWidget {
  const _LessonPane({required this.chapter, required this.lessons});

  final ChapterNode chapter;
  final List<Lesson> lessons;

  @override
  Widget build(BuildContext context) {
    final coursePkgs = lessons.where((l) => l.isCoursePackage).toList();
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              chapter.title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ),
        if (coursePkgs.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('本章暂无课程包')),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            sliver: SliverList.builder(
              itemCount: coursePkgs.length,
              itemBuilder: (context, i) =>
                  _LessonCard(lesson: coursePkgs[i]),
            ),
          ),
      ],
    );
  }
}

class _LessonCard extends StatefulWidget {
  const _LessonCard({required this.lesson});

  final Lesson lesson;

  @override
  State<_LessonCard> createState() => _LessonCardState();
}

class _LessonCardState extends State<_LessonCard> {
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final entry = app.watchEntryOf(widget.lesson.id);
    final cover = app.coverUrlOf(widget.lesson.id);
    final progress = entry != null && entry.durationSec > 0
        ? (entry.positionSec / entry.durationSec).clamp(0.0, 1.0)
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  PlayerPage(resId: widget.lesson.id, title: widget.lesson.title),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _Cover(coverUrl: cover),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.lesson.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15)),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (widget.lesson.week != null) widget.lesson.week!,
                          if (entry != null)
                            '看到 ${(entry.positionSec / 60).floor()} 分钟'
                          else
                            '国家课程',
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (progress != null) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 3,
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.play_circle_fill,
                    color: Theme.of(context).colorScheme.primary, size: 34),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({this.coverUrl});

  final Uri? coverUrl;

  @override
  Widget build(BuildContext context) {
    if (coverUrl == null) {
      return Container(
        width: 116,
        height: 66,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Theme.of(context).colorScheme.primaryContainer,
        ),
        child: Icon(Icons.play_arrow_rounded,
            size: 30, color: Theme.of(context).colorScheme.onPrimaryContainer),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        coverUrl.toString(),
        width: 116,
        height: 66,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: 116,
          height: 66,
          color: Theme.of(context).colorScheme.primaryContainer,
        ),
      ),
    );
  }
}

/// Cascading tag picker: 学段 → 年级 → 学科 → 版本 → 册次 → 新旧教材.
class _TextbookPickerDialog extends StatefulWidget {
  const _TextbookPickerDialog();

  @override
  State<_TextbookPickerDialog> createState() => _TextbookPickerDialogState();
}

class _TextbookPickerDialogState extends State<_TextbookPickerDialog> {
  static const _dims = [
    ('zxxxd', '学段'),
    ('zxxnj', '年级'),
    ('zxxxk', '学科'),
    ('zxxbb', '版本'),
    ('zxxcc', '册次'),
    ('zxxxjjc', '教材'),
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final tree = app.catalog.tagTree;
    if (tree == null) {
      return const AlertDialog(content: CircularProgressIndicator());
    }
    final sel = app.selection;
    final size = MediaQuery.sizeOf(context);
    final dialogMax = size.width * 0.9;

    return AlertDialog(
      title: const Text('筛选教材（年级 / 版本 / 册次）'),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      content: SizedBox(
        width: dialogMax > 640 ? 640 : dialogMax,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (dim, label) in _dims)
              _DimRow(
                label: label,
                options: _optionsFor(tree, sel, dim),
                selected: _selectedId(sel, dim),
                onPick: (id) =>
                    app.updateSelection(_withDim(sel, dim, id)),
              ),
            const Divider(height: 24),
            Flexible(
              child: _MaterialMatches(sel: sel),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  String? _selectedId(Selection sel, String dim) => switch (dim) {
        'zxxxd' => sel.stageId,
        'zxxnj' => sel.gradeId,
        'zxxxk' => sel.subjectId,
        'zxxbb' => sel.editionId,
        'zxxcc' => sel.volumeId,
        _ => sel.oldNewId,
      };

  Selection _withDim(Selection sel, String dim, String? id) => switch (dim) {
        'zxxxd' => sel.copyWith(
            stageId: id ?? sel.stageId,
            clearGrade: true,
            clearSubject: true,
            clearEdition: true,
            clearVolume: true,
            clearOldNew: true),
        'zxxnj' => sel.copyWith(
            gradeId: id,
            clearSubject: true,
            clearEdition: true,
            clearVolume: true,
            clearOldNew: true),
        'zxxxk' => sel.copyWith(
            subjectId: id,
            clearEdition: true,
            clearVolume: true,
            clearOldNew: true),
        'zxxbb' =>
          sel.copyWith(editionId: id, clearVolume: true, clearOldNew: true),
        'zxxcc' => sel.copyWith(volumeId: id, clearOldNew: true),
        _ => sel.copyWith(oldNewId: id),
      };

  List<TagNode> _optionsFor(TagTree tree, Selection sel, String dim) {
    List<TagNode> level = tree.roots;
    for (final d in _dims) {
      final id = _selectedId(sel, d.$1);
      if (d.$1 == dim) return level;
      if (id == null) return const [];
      TagNode? match;
      for (final n in level) {
        if (n.id == id) match = n;
      }
      if (match == null) return const [];
      level = match.children;
    }
    return const [];
  }
}

class _DimRow extends StatelessWidget {
  const _DimRow({
    required this.label,
    required this.options,
    required this.selected,
    required this.onPick,
  });

  final String label;
  final List<TagNode> options;
  final String? selected;
  final void Function(String?) onPick;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.outline)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final o in options)
                ChoiceChip(
                  label: Text(o.name, style: const TextStyle(fontSize: 13)),
                  selected: selected == o.id,
                  onSelected: (on) => onPick(on ? o.id : null),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MaterialMatches extends StatelessWidget {
  const _MaterialMatches({required this.sel});

  final Selection sel;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    if (sel.stageId == null) return const SizedBox.shrink();
    final matches = app.catalog.filter(
      stageId: sel.stageId!,
      gradeId: sel.gradeId,
      subjectId: sel.subjectId,
      editionId: sel.editionId,
      volumeId: sel.volumeId,
      oldNewId: sel.oldNewId,
    );
    if (matches.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text('没有匹配的教材，请调整筛选',
            style: TextStyle(color: Theme.of(context).colorScheme.outline)),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: [
        for (final m in matches)
          ListTile(
            dense: true,
            selected: app.material?.id == m.id,
            title: Text(m.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [m.tags['zxxbb'], m.tags['zxxcc'], m.tags['zxxxjjc']]
                  .whereType<String>()
                  .where((s) => s.isNotEmpty)
                  .join(' · '),
              maxLines: 1,
            ),
            onTap: () {
              Navigator.of(context).pop();
              app.openMaterial(m);
            },
          ),
      ],
    );
  }
}
