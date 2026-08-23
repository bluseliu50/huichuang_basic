import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../store/app_state.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final history = app.history.take(12).toList();
    final hour = DateTime.now().hour;
    final greeting = hour < 6
        ? '夜深了'
        : hour < 12
            ? '早上好'
            : hour < 18
                ? '下午好'
                : '晚上好';

    return Scaffold(
      appBar: AppBar(title: const Text('惠窗中小学端')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        children: [
          Text(
            '$greeting，继续学习吧',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 20),
          if (history.isNotEmpty) ...[
            _SectionHeader(
              title: '继续观看',
              actionText: '清空',
              onAction: () => context.read<AppController>().clearHistory(),
            ),
            SizedBox(
              height: 132,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: history.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, i) => _ContinueCard(entry: history[i]),
              ),
            ),
            const SizedBox(height: 12),
          ],
          _SectionHeader(
            title: '快速开始',
            actionText: '前往课程教学',
            onAction: () => DefaultTabController.maybeOf(context) == null
                ? _goToCourses(context)
                : null,
          ),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final m in _quickMaterials(app).take(8))
                ActionChip(
                  label: Text(m.title),
                  onPressed: () {
                    _goToCourses(context);
                    context.read<AppController>().openMaterial(m);
                  },
                ),
            ],
          ),
          const SizedBox(height: 32),
          Text(
            '惠窗中小学端是一个非官方第三方客户端，仅供个人学习使用。\n平台内容版权归国家中小学智慧教育平台及资源提供方所有。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
      ),
    );
  }

  void _goToCourses(BuildContext context) {
    // The shell owns tab state; simplest cross-page navigation is a
    // notification the shell listens for.
    SwitchTabNotification(1).dispatch(context);
  }

  List<TeachingMaterial> _quickMaterials(AppController app) {
    final mats = app.catalog.materials ?? const [];
    // Recently opened or default 统编版语文 picks.
    return mats.where((m) => m.tags['zxxxk'] == '语文').take(8).toList();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.actionText, this.onAction});

  final String title;
  final String? actionText;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          if (actionText != null)
            TextButton(onPressed: onAction, child: Text(actionText!)),
        ],
      ),
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
      width: 220,
      child: Card(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: () => OpenLessonNotification(entry.resId).dispatch(context),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                const Spacer(),
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

/// Requests the shell to switch tab.
class SwitchTabNotification extends Notification {
  const SwitchTabNotification(this.index);
  final int index;
}

/// Requests opening a lesson (player).
class OpenLessonNotification extends Notification {
  const OpenLessonNotification(this.resId);
  final String resId;
}
