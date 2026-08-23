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
            label: Text(app.material?.title ?? '选择教材'),
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
              : const _BrowserBody(),
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

/// Desktop: chapter tree + lesson list side by side.
/// Mobile: single scrolling list of expandable chapters.
class _BrowserBody extends StatelessWidget {
  const _BrowserBody();

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
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 340,
            child: _ChapterTree(app: app),
          ),
          const VerticalDivider(width: 1),
          const Expanded(child: _LessonPane()),
        ],
      );
    }
    return _ChapterTree(app: app, expandedAll: false);
  }
}

class _ChapterTree extends StatelessWidget {
  const _ChapterTree({required this.app, this.expandedAll = true});

  final AppController app;
  final bool expandedAll;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      itemCount: app.chapters.length,
      itemBuilder: (context, i) => _ChapterTile(
        node: app.chapters[i],
        app: app,
        initiallyExpanded: expandedAll,
        depth: 0,
      ),
    );
  }
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    required this.node,
    required this.app,
    required this.initiallyExpanded,
    required this.depth,
  });

  final ChapterNode node;
  final AppController app;
  final bool initiallyExpanded;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final lessons = app.lessonsFor(node);
    final hasChildren = node.children?.isNotEmpty == true;
    if (!hasChildren) {
      return Padding(
        padding: EdgeInsets.only(left: 14.0 * depth),
        child: ListTile(
          dense: true,
          title: Text(node.title,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: lessons.isEmpty
              ? null
              : Badge(label: Text('${lessons.length}')),
          onTap: lessons.isEmpty
              ? null
              : () => _openLessons(context, node.title, lessons),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(left: 10.0 * depth),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded && depth == 0,
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(node.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: lessons.isEmpty ? null : Text('${lessons.length} 个课程'),
        children: [
          for (final l in lessons)
            _LessonTile(lesson: l),
          for (final c in node.children!)
            _ChapterTile(
              node: c,
              app: app,
              initiallyExpanded: initiallyExpanded,
              depth: depth + 1,
            ),
        ],
      ),
    );
  }

  void _openLessons(BuildContext context, String title, List<Lesson> lessons) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _LessonSheetPage(title: title, lessons: lessons),
      ),
    );
  }
}

class _LessonTile extends StatelessWidget {
  const _LessonTile({required this.lesson});

  final Lesson lesson;

  @override
  Widget build(BuildContext context) {
    final entry = context
        .read<AppController>()
        .watchEntryOf(lesson.id);
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: ListTile(
        dense: true,
        leading: lesson.isCoursePackage
            ? Icon(Icons.play_circle_outline,
                color: Theme.of(context).colorScheme.primary)
            : const Icon(Icons.description_outlined, size: 20),
        title: Text(lesson.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: entry == null
            ? null
            : const Icon(Icons.history, size: 16),
        onTap: () => _open(context, lesson),
      ),
    );
  }

  void _open(BuildContext context, Lesson lesson) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(resId: lesson.id, title: lesson.title),
      ),
    );
  }
}

class _LessonSheetPage extends StatelessWidget {
  const _LessonSheetPage({required this.title, required this.lessons});

  final String title;
  final List<Lesson> lessons;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        children: [for (final l in lessons) _LessonTile(lesson: l)],
      ),
    );
  }
}

/// Right pane on desktop: lessons of the selected/first chapter inline.
class _LessonPane extends StatelessWidget {
  const _LessonPane();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final coursePkg =
        app.lessons.where((l) => l.isCoursePackage).toList();
    if (coursePkg.isEmpty) {
      return const Center(child: Text('本章暂无课程包'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: coursePkg.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final l = coursePkg[i];
        final entry = app.watchEntryOf(l.id);
        return Card(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: const _CoverThumb(),
            title: Text(l.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: entry == null
                ? Text(l.week ?? '国家课程')
                : Text('看到 ${entry.positionSec.round()} 秒'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    PlayerPage(resId: l.id, title: l.title),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CoverThumb extends StatelessWidget {
  const _CoverThumb();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Icon(Icons.play_arrow_rounded,
          color: Theme.of(context).colorScheme.onPrimaryContainer),
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
      title: const Text('选择教材'),
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
                onPick: (id) => app.updateSelection(
                  _withDim(sel, dim, id),
                ),
              ),
            const Divider(height: 24),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
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
            subjectId: id, clearEdition: true, clearVolume: true, clearOldNew: true),
        'zxxbb' => sel.copyWith(editionId: id, clearVolume: true, clearOldNew: true),
        'zxxcc' => sel.copyWith(volumeId: id, clearOldNew: true),
        _ => sel.copyWith(oldNewId: id),
      };

  List<TagNode> _optionsFor(TagTree tree, Selection sel, String dim) {
    List<TagNode> level = tree.roots;
    for (final d in _dims) {
      final id = _selectedId(sel, d.$1);
      if (d.$1 == dim) return level;
      final match = level.where((n) => n.id == id).firstOrNull;
      if (match == null) return d.$1 == dim ? level : const [];
      level = match.children;
    }
    return const [];
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
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
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.outline)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final o in options)
                ChoiceChip(
                  label: Text(o.name),
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
            title: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
