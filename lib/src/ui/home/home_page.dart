import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../store/app_state.dart';
import '../courses/courses_page.dart';
import '../player/player_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, this.onOpenCourses});

  /// Switches the shell to the 课程教学 tab after a subject shortcut jump.
  final VoidCallback? onOpenCourses;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final history = app.history.take(10).toList();
    final hour = DateTime.now().hour;
    final greeting = hour < 6
        ? '夜深了'
        : hour < 12
            ? '早上好'
            : hour < 18
                ? '下午好'
                : '晚上好';
    final catalogLoading = app.catalogPhase == LoadPhase.loading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('惠窗中小学端'),
        actions: [
          if (!catalogLoading)
            TextButton.icon(
              onPressed: () => showTextbookPicker(context),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('选课'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: catalogLoading && app.catalog.materials == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              children: [
                Text(
                  '$greeting，继续学习吧',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 20),
                if (history.isNotEmpty) ...[
                  const _Header('继续观看'),
                  SizedBox(
                    height: 216,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: history.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (context, i) =>
                          _ContinueCard(entry: history[i]),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                const _Header('快速开始'),
                _QuickStart(
                    tree: app.catalog.tagTree, onOpenCourses: onOpenCourses),
                const SizedBox(height: 28),
                Text(
                  '惠窗中小学端是非官方第三方客户端，仅供个人学习使用。\n平台内容版权归国家中小学智慧教育平台及资源提供方所有。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ],
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w600)),
    );
  }
}

/// 学段 chips → tapping opens the textbook picker; 学科 shortcuts for the
/// first stage.
class _QuickStart extends StatelessWidget {
  const _QuickStart({required this.tree, this.onOpenCourses});

  final TagTree? tree;
  final VoidCallback? onOpenCourses;

  @override
  Widget build(BuildContext context) {
    final tree = this.tree;
    if (tree == null || tree.roots.isEmpty) {
      return Text('目录尚未就绪',
          style: TextStyle(color: Theme.of(context).colorScheme.outline));
    }
    final stages = tree.roots;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final stage in stages)
              ActionChip(
                avatar: Icon(_stageIcon(stage.name),
                    size: 18, color: Theme.of(context).colorScheme.primary),
                label: Text(stage.name),
                onPressed: () => showTextbookPicker(context),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text('常用科目',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.outline)),
        const SizedBox(height: 8),
        _CommonSubjects(stages: stages, onOpenCourses: onOpenCourses),
      ],
    );
  }

  IconData _stageIcon(String name) {
    if (name.contains('小学')) return Icons.child_care_outlined;
    if (name.contains('初中')) return Icons.school_outlined;
    if (name.contains('高中')) return Icons.menu_book_outlined;
    return Icons.auto_stories_outlined;
  }
}

class _CommonSubjects extends StatelessWidget {
  const _CommonSubjects({required this.stages, this.onOpenCourses});

  final List<TagNode> stages;
  final VoidCallback? onOpenCourses;

  static const _common = ['语文', '数学', '英语', '道德与法治', '科学', '体育与健康'];

  @override
  Widget build(BuildContext context) {
    // Subject shortcuts of the first stage; each remembers its parent grade
    // so a first-time jump still resolves to a valid (stage, grade, subject).
    final stage = stages.first;
    final subjects = <(String, String, TagNode)>[
      for (final g in stage.children)
        for (final s in g.children)
          if (_common.contains(s.name)) (stage.id, g.id, s),
    ];
    final seen = <String>{};
    final unique = subjects.where((t) => seen.add(t.$3.name)).toList();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (stageId, gradeId, s) in unique.take(12))
          OutlinedButton(
            onPressed: () {
              final app = context.read<AppController>();
              final opened = app.selectSubject(
                stageId: stageId,
                subjectId: s.id,
                fallbackGradeId: gradeId,
              );
              onOpenCourses?.call();
              if (!opened) showTextbookPicker(context);
            },
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size(0, 40),
            ),
            child: Text(s.name),
          ),
      ],
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.entry});

  final WatchEntry entry;

  @override
  Widget build(BuildContext context) {
    final progress = entry.durationSec > 0
        ? (entry.positionSec / entry.durationSec).clamp(0.0, 1.0)
        : 0.0;
    return SizedBox(
      width: 230,
      child: Card(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  PlayerPage(
                      resId: entry.resId,
                      title: entry.title,
                      tmId: entry.tmId.isEmpty ? null : entry.tmId),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Full 16:9 cover — never crop into a wide sliver.
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: entry.coverUrl != null
                        ? CachedNetworkImage(
                            imageUrl: entry.coverUrl!,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => Container(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer,
                            ),
                          )
                        : Container(
                            color: Theme.of(context)
                                .colorScheme
                                .primaryContainer,
                            child: Icon(Icons.play_circle_outline,
                                size: 34,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Icon(Icons.play_circle_outline,
                      size: 20, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ]),
                Text(
                  '${_fmt(entry.positionSec)} / ${_fmt(entry.durationSec)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _fmt(double s) {
    final m = (s / 60).floor();
    final sec = (s % 60).floor();
    return '$m:${sec.toString().padLeft(2, '0')}';
  }
}
