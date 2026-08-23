import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../store/app_state.dart';
import '../../stream/proxy.dart';
import '../login/login_card.dart';
import '../pdf/pdf_reader_page.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.resId,
    required this.title,
    this.tmId,
  });

  final String resId;
  final String title;

  /// Teaching material the lesson belongs to; falls back to the currently
  /// open material so watch history can deep-link back to its course.
  final String? tmId;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  AppController? _appController;
  Player? _player;
  VideoController? _controller;
  ResourceDetail? _detail;
  String? _error;
  bool _loading = true;
  double? _resumeAt;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  Duration _lastRecorded = Duration.zero;
  bool _recorded = false;

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final auth = context.read<AuthController>();
    _appController = context.read<AppController>();
    final appController = _appController!;
    final client = context.read<SmarteduClient>();
    final proxy_ = context.read<StreamProxy>();
    final token = await auth.ensureValidToken();
    if (!mounted) return;
    if (token == null) {
      setState(() {
        _loading = false;
        _error = '需要登录后才能播放';
      });
      return;
    }
    try {
      final detail = await client.getResourceDetail(widget.resId);
      final video = detail.video;
      if (video == null || video.storages.isEmpty) {
        throw StateError('该课程没有可播放的视频');
      }
      proxy_.register(widget.resId, video.storages);
      debugPrint('registered ${video.storages.length} mirrors');
      final proxy = proxy_;

      final entry = appController.watchEntryOf(widget.resId);
      _resumeAt = entry != null && entry.positionSec > 30 && entry.durationSec <= 0
          ? null
          : (entry != null && entry.positionSec > 30 ? entry.positionSec : null);

      final player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 32 * 1024 * 1024,
        ),
      );
      final native = player.platform;
      if (native is NativePlayer) {
        await native.setProperty('hwdec', 'auto-safe');
        await native.setProperty('cache-pause', 'no');
      }
      final controller = VideoController(player);

      debugPrint('PLAYER_OPEN url=${proxy.playlistUrl(widget.resId)}');
      player.stream.duration.listen((d) {
        if (d > Duration.zero) debugPrint('PLAYER_DURATION ${d.inSeconds}s');
      });
      _positionSub = player.stream.position.listen(_onPosition);
      _completedSub = player.stream.completed.listen((done) {
        if (done) _record();
      });
      _errorSub = player.stream.error.listen((e) {
        if (e.isNotEmpty && mounted && _player != null) {
          setState(() => _error = '播放出错：$e');
        }
      });

      await player.open(Media(proxy.playlistUrl(widget.resId).toString()));
      if (_resumeAt != null) {
        unawaited(player.seek(Duration(seconds: _resumeAt!.round())));
      }

      setState(() {
        _player = player;
        _controller = controller;
        _detail = detail;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  void _onPosition(Duration position) {
    final every = const Duration(seconds: 5);
    if (position - _lastRecorded < every && position > _lastRecorded) return;
    _lastRecorded = position;
    _record();
  }

  Future<void> _record() async {
    final p = _player;
    if (p == null) return;
    final pos = p.state.position;
    final dur = p.state.duration;
    if (dur == Duration.zero) return;
    if (!_recorded && pos == Duration.zero) return;
    _recorded = true;
    await _appController?.recordWatch(
          resId: widget.resId,
          title: _detail?.title ?? widget.title,
          tmId: widget.tmId ?? _appController?.material?.id ?? '',
          positionSec: pos.inMilliseconds / 1000,
          durationSec: dur.inMilliseconds / 1000,
          coverUrl: _appController?.coverUrlOf(widget.resId)?.toString(),
        );
  }

  @override
  void dispose() {
    _record();
    _positionSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
            ? _ErrorCard(
                message: _error!,
                onRetry: () {
                  setState(() {
                    _error = null;
                    _loading = true;
                  });
                  _player?.dispose();
                  _player = null;
                  _load();
                },
              )
            : wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Video as large as possible, docked left.
                      Expanded(child: _buildVideoMax(context)),
                      SizedBox(
                        width: 360,
                        child: _buildSidebar(context),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(
                        flex: 5,
                        child: _buildVideo(context),
                      ),
                      Expanded(
                        flex: 4,
                        child: _buildBelow(context),
                      ),
                    ],
                  );

    return Scaffold(
      appBar: AppBar(
        title: Text(_detail?.title ?? widget.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: body,
    );
  }

  Widget _buildVideo(BuildContext context) {
    final c = _controller;
    if (c == null) return const SizedBox.shrink();
    return Center(
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Video(
          controller: c,
          controls: (state) => _HuichuangControls(
            state: state,
            isDesktop: _isDesktop,
          ),
        ),
      ),
    );
  }

  /// Wide layout: video fills the whole left pane (letterboxed by mpv).
  Widget _buildVideoMax(BuildContext context) {
    final c = _controller;
    if (c == null) return const SizedBox.shrink();
    return ColoredBox(
      color: Colors.black,
      child: Video(
        controller: c,
        controls: (state) => _HuichuangControls(
          state: state,
          isDesktop: _isDesktop,
        ),
      ),
    );
  }

  /// Lessons around the current one: the leaf chapter's own lessons, or —
  /// when the leaf holds a single course — the whole enclosing unit so
  /// sibling 课时 stay reachable. Null when the open material doesn't match
  /// this player's context.
  (String, List<Lesson>)? _chapterLessons() {
    final app = _appController;
    final material = app?.material;
    if (app == null || material == null) return null;
    if (material.id != (widget.tmId ?? material.id)) return null;
    Lesson? current;
    for (final l in app.lessons) {
      if (l.id == widget.resId) current = l;
    }
    final ids = current?.chapterIds;
    if (ids == null || ids.isEmpty) return null;

    ChapterNode? find(List<ChapterNode> nodes, String id) {
      for (final n in nodes) {
        if (n.id == id) return n;
        final hit = find(n.children ?? const [], id);
        if (hit != null) return hit;
      }
      return null;
    }

    List<Lesson> lessonsUnder(ChapterNode n) => [
          ...app.lessonsFor(n),
          for (final c in n.children ?? const <ChapterNode>[])
            ...lessonsUnder(c),
        ];

    final leaf = find(app.chapters, ids.last);
    if (leaf == null) return null;
    var group = leaf;
    var lessons = lessonsUnder(leaf);
    if (lessons.length <= 1 && ids.length >= 2) {
      final parent = find(app.chapters, ids[ids.length - 2]);
      if (parent != null) {
        final wider = lessonsUnder(parent);
        if (wider.length > lessons.length) {
          group = parent;
          lessons = wider;
        }
      }
    }
    return (group.title, lessons);
  }

  Widget _buildSidebar(BuildContext context) {
    final d = _detail;
    if (d == null) return const SizedBox.shrink();
    final docs = d.related.where((r) => !r.isVideo).toList();
    final chapter = _chapterLessons();
    final app = _appController;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_resumeAt != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '已从上次位置继续（${_resumeAt!.round()} 秒处）',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ),
        Text(d.title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          [
            if (d.teachers.isNotEmpty) d.teachers.join('、'),
            if (d.provider != null) d.provider!,
          ].join(' · '),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
        if (chapter != null) ...[
          const SizedBox(height: 16),
          Text('课时选择 · ${chapter.$1}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          for (final l in chapter.$2)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              selected: l.id == widget.resId,
              selectedTileColor:
                  Theme.of(context).colorScheme.secondaryContainer,
              leading: Icon(
                l.isCoursePackage
                    ? Icons.play_circle_outline
                    : Icons.description_outlined,
                size: 18,
                color: l.id == widget.resId
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outline,
              ),
              title: Text(l.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5)),
              onTap: l.id == widget.resId
                  ? null
                  : () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute<void>(
                        builder: (_) => PlayerPage(
                          resId: l.id,
                          title: l.title,
                          tmId: widget.tmId ?? app?.material?.id,
                        ),
                      ),
                    ),
              ),
        ],
        if (docs.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('课时资源',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final doc in docs)
                ActionChip(
                  avatar: Icon(_iconFor(doc.format),
                      size: 18, color: Theme.of(context).colorScheme.primary),
                  label: Text(doc.typeName ?? doc.format ?? doc.title),
                  onPressed: () => _openDoc(context, doc),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildBelow(BuildContext context) {
    final d = _detail;
    if (d == null) return const SizedBox.shrink();
    final related = d.related;
    final docs = related.where((r) => !r.isVideo).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_resumeAt != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '已从上次位置继续（${_resumeAt!.round()} 秒处）',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.title,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (d.teachers.isNotEmpty) d.teachers.join('、'),
                      if (d.provider != null) d.provider!,
                    ].join(' · '),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (docs.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('课时资源',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final doc in docs)
                ActionChip(
                  avatar: Icon(_iconFor(doc.format),
                      size: 18, color: Theme.of(context).colorScheme.primary),
                  label: Text(doc.typeName ?? doc.format ?? doc.title),
                  onPressed: () => _openDoc(context, doc),
                ),
            ],
          ),
        ],
      ],
    );
  }

  IconData _iconFor(String? format) => switch (format) {
        'pdf' => Icons.picture_as_pdf_outlined,
        'ppt' || 'pptx' => Icons.slideshow_outlined,
        'doc' || 'docx' => Icons.description_outlined,
        _ => Icons.insert_drive_file_outlined,
      };

  Future<void> _openDoc(BuildContext context, RelatedResource doc) async {
    if (doc.storages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该资源没有可用文件')),
      );
      return;
    }
    final proxy = context.read<StreamProxy>();
    final url = proxy.fileUrl(doc.storages.first);
    if ((doc.format ?? '').toLowerCase() == 'pdf') {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PdfReaderPage(title: doc.title, url: url),
        ),
      );
      return;
    }
    // Non-PDF: download through the proxy and hand to the system.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('正在下载 ${doc.title} …')),
    );
    try {
      final client = HttpClient();
      final req = await client.getUrl(url);
      final res = await req.close();
      final name =
          '${doc.title}.${(doc.format ?? 'bin').replaceAll(RegExp(r'[^a-z0-9]'), '')}';
      final dir = _isDesktop
          ? Directory.systemTemp
          : await _mobileDownloads();
      final file = File('${dir.path}/$name');
      final sink = file.openWrite();
      await for (final chunk in res) {
        sink.add(chunk);
      }
      await sink.close();
      if (_isDesktop) {
        final opener = Platform.isMacOS
            ? 'open'
            : Platform.isLinux
                ? 'xdg-open'
                : 'cmd';
        final args = Platform.isWindows ? ['/c', 'start', '', file.path] : [file.path];
        await Process.run(opener, args);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已保存到 ${file.path}')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败：$e')),
        );
      }
    }
  }
}

Future<Directory> _mobileDownloads() async {
  // Android/iOS: cache directory is app-writable and user-reachable
  // through files app on Android.
  final base = Directory.systemTemp;
  return base;
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final needsLogin = message.contains('登录');
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline,
              size: 44, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 16),
          needsLogin
              ? FilledButton(
                  onPressed: () => showLoginCard(context),
                  child: const Text('去登录'),
                )
              : FilledButton.tonal(
                  onPressed: onRetry,
                  child: const Text('重试'),
                ),
        ],
      ),
    );
  }
}

/// Custom control bar: mouse + touch, keyboard shortcuts, drag gestures.
class _HuichuangControls extends StatefulWidget {
  const _HuichuangControls({
    required this.state,
    required this.isDesktop,
  });

  final VideoState state;
  final bool isDesktop;

  @override
  State<_HuichuangControls> createState() => _HuichuangControlsState();
}

class _HuichuangControlsState extends State<_HuichuangControls> {
  final _focusNode = FocusNode();
  bool _visible = true;
  Timer? _hideTimer;
  double _dragStartDx = 0;
  double _dragStartDy = 0;
  Duration _seekBase = Duration.zero;
  double _volumeBase = 0;
  bool _draggingSeek = false;
  bool _draggingVolume = false;
  Duration? _dragPreview;
  double? _volumePreview;
  double _speed = 1.0;

  Player get _player => widget.state.widget.controller.player;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && widget.state.widget.controller.player.state.playing) {
        setState(() => _visible = false);
      }
    });
  }

  void _poke() {
    setState(() => _visible = true);
    _scheduleHide();
  }

  Future<void> _togglePlay() async {
    final p = _player;
    await p.playOrPause();
    _poke();
  }

  Future<void> _seekBy(int seconds) async {
    final p = _player;
    final target = p.state.position + Duration(seconds: seconds);
    await p.seek(target);
    _poke();
  }

  Future<void> _toggleFullscreen() async {
    if (widget.isDesktop) {
      final isFs = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!isFs);
    } else {
      final route = FullscreenVideoRoute(
          child: Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: widget.state.widget),
      ));
      await Navigator.of(context).push(route);
    }
  }

  Future<void> _setSpeed(double s) async {
    await _player.setRate(s);
    setState(() => _speed = s);
    _poke();
  }

  // ------------------------------------------------------------- gestures

  void _onPointerDown(PointerDownEvent e) {
    _dragStartDx = e.position.dx;
    _dragStartDy = e.position.dy;
    _seekBase = _player.state.position;
    _volumeBase = _player.state.volume;
    _draggingSeek = false;
    _draggingVolume = false;
  }

  void _onPointerMove(PointerMoveEvent e) {
    final dx = e.position.dx - _dragStartDx;
    final dy = e.position.dy - _dragStartDy;
    if (!_draggingSeek && !_draggingVolume && dx.abs() > dy.abs() && dx.abs() > 14) {
      _draggingSeek = true;
    } else if (!_draggingSeek &&
        !_draggingVolume &&
        dy.abs() > 14 &&
        e.position.dx > MediaQuery.sizeOf(context).width / 2) {
      _draggingVolume = true;
    }
    if (_draggingSeek) {
      final width = MediaQuery.sizeOf(context).width;
      final deltaSec = (dx / width) *
          (widget.state.widget.controller.player.state.duration.inSeconds
                  .clamp(60, 600)) *
          2;
      _dragPreview =
          _seekBase + Duration(seconds: deltaSec.round());
      setState(() {});
    } else if (_draggingVolume) {
      final height = MediaQuery.sizeOf(context).height;
      final dv = (-dy / height) * 100;
      _volumePreview = (_volumeBase + dv).clamp(0.0, 100.0);
      setState(() {});
    }
  }

  Future<void> _onPointerUp(PointerUpEvent e) async {
    if (_draggingSeek && _dragPreview != null) {
      await _player.seek(_dragPreview!);
    } else if (_draggingVolume && _volumePreview != null) {
      await _player.setVolume(_volumePreview!);
    }
    _dragPreview = null;
    _volumePreview = null;
    _draggingSeek = false;
    _draggingVolume = false;
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final media = widget.state.widget.controller.player;
    final position = media.state.position;
    final duration = media.state.duration;
    final bufferedEnd = media.state.buffer;

    return Focus(
      autofocus: widget.isDesktop,
      child: KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: MouseRegion(
        // Desktop: hovering reveals the control bar — no click needed.
        onHover: widget.isDesktop ? (_) => _poke() : null,
        child: Listener(
        onPointerDown: (e) {
          _onPointerDown(e);
          _poke();
        },
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onDoubleTap: _toggleFullscreen,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Progress-independent overlays.
              if (_dragPreview != null) _dragOverlay('$_fmtDur(_dragPreview!)'),
              if (_volumePreview != null)
                _dragOverlay('音量 ${_volumePreview!.round()}%'),
              AnimatedOpacity(
                opacity: _visible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_visible,
                  child: Column(
                    children: [
                      const Spacer(),
                      // Top gradient with title omitted — appbar has it.
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.55),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _ProgressBar(
                              position: position,
                              duration: duration,
                              bufferedEnd: bufferedEnd,
                              onSeek: (d) => media.seek(d),
                            ),
                            Row(
                              children: [
                                IconButton(
                                  tooltip: '播放/暂停 (空格)',
                                  icon: Icon(
                                    media.state.playing
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    color: Colors.white,
                                  ),
                                  onPressed: _togglePlay,
                                ),
                                IconButton(
                                  tooltip: '后退 10 秒 (←)',
                                  icon: const Icon(Icons.replay_10,
                                      color: Colors.white),
                                  onPressed: () => _seekBy(-10),
                                ),
                                IconButton(
                                  tooltip: '前进 10 秒 (→)',
                                  icon: const Icon(Icons.forward_10,
                                      color: Colors.white),
                                  onPressed: () => _seekBy(10),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8),
                                  child: Text(
                                    '${_fmtDur(position)} / ${_fmtDur(duration)}',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 13),
                                  ),
                                ),
                                const Spacer(),
                                if (widget.isDesktop)
                                  _VolumeControl(
                                    player: media,
                                  ),
                                PopupMenuButton<double>(
                                  tooltip: '倍速',
                                  initialValue: _speed,
                                  onSelected: _setSpeed,
                                  itemBuilder: (_) => [
                                    for (final s in const [
                                      0.5, 0.75, 1.0, 1.25, 1.5, 2.0
                                    ])
                                      PopupMenuItem(
                                        value: s,
                                        child: Text(
                                            s == 1.0 ? '正常' : '$s×'),
                                      ),
                                  ],
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10),
                                    child: Text(
                                      _speed == 1.0 ? '倍速' : '$_speed×',
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 13),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '全屏 (F)',
                                  icon: const Icon(Icons.fullscreen,
                                      color: Colors.white),
                                  onPressed: _toggleFullscreen,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        ),
      ),
      ),
    );
  }

  void _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.keyK) {
      _togglePlay();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-10);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(10);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      mediaVolume(5);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      mediaVolume(-5);
    } else if (key == LogicalKeyboardKey.keyF ||
        key == LogicalKeyboardKey.keyM) {
      _toggleFullscreen();
    } else if (key == LogicalKeyboardKey.escape) {
      if (widget.isDesktop) {
        windowManager.setFullScreen(false);
      }
    }
  }

  Future<void> mediaVolume(int delta) async {
    final v = (_player.state.volume + delta).clamp(0.0, 100.0);
    await _player.setVolume(v);
    _poke();
  }

  void _toggleControls() {
    setState(() => _visible = !_visible);
    if (_visible) _scheduleHide();
  }

  Widget _dragOverlay(String text) => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(text,
              style: const TextStyle(
                  color: Colors.white, fontSize: 16)),
        ),
      );
}

String _fmtDur(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
}

class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    required this.position,
    required this.duration,
    required this.bufferedEnd,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final Duration bufferedEnd;
  final Future<void> Function(Duration) onSeek;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  bool _dragging = false;
  double _dragValue = 0;

  @override
  Widget build(BuildContext context) {
    final total = widget.duration.inMilliseconds;
    final pos = widget.position.inMilliseconds;
    final value = total <= 0
        ? 0.0
        : (_dragging ? _dragValue : pos / total);
    final bufferedEnd = total <= 0
        ? 0.0
        : widget.bufferedEnd.inMilliseconds / total;

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) {
          setState(() {
            _dragging = true;
            _dragValue = value;
          });
        },
        onHorizontalDragUpdate: (d) {
          setState(() {
            _dragValue =
                (_dragValue + d.delta.dx / width).clamp(0.0, 1.0);
          });
        },
        onHorizontalDragEnd: (_) async {
          await widget.onSeek(Duration(
              milliseconds: (_dragValue * total).round()));
          setState(() => _dragging = false);
        },
        onTapUp: (d) async {
          final frac = (d.localPosition.dx / width).clamp(0.0, 1.0);
          await widget.onSeek(
              Duration(milliseconds: (frac * total).round()));
        },
        child: SizedBox(
          height: 22,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: bufferedEnd.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: Colors.white24,
                  valueColor:
                      const AlwaysStoppedAnimation(Colors.white38),
                ),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: value.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: Colors.transparent,
                  valueColor:
                      const AlwaysStoppedAnimation(Color(0xFF5B8DEF)),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

class _VolumeControl extends StatelessWidget {
  const _VolumeControl({required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: player.stream.volume,
      builder: (context, snap) {
        final v = snap.data ?? player.state.volume;
        return SizedBox(
          width: 120,
          child: Slider(
            value: v.clamp(0.0, 100.0),
            min: 0,
            max: 100,
            onChanged: (nv) => player.setVolume(nv),
          ),
        );
      },
    );
  }
}

class FullscreenVideoRoute extends PageRouteBuilder<void> {
  FullscreenVideoRoute({required Widget child})
      : super(
          pageBuilder: (_, _, _) => child,
          fullscreenDialog: true,
          opaque: true,
          transitionDuration: Duration.zero,
        );
}
