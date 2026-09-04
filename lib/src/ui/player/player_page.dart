import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../store/app_state.dart';
import '../../stream/proxy.dart';
import '../breakpoints.dart';
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
  LessonPeriod? _period;
  String? _error;
  bool _loading = true;
  double? _resumeAt;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  Duration _lastRecorded = Duration.zero;
  bool _recorded = false;
  Future<void>? _disposeJob;
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
      // Multi-period packs (bkks) play one 备课课时 at a time; restore the
      // last one used.
      final periods = detail.periods;
      LessonPeriod? period;
      if (periods.isNotEmpty) {
        final remembered = (await SharedPreferences.getInstance()).getString(
          'hc_lesson_period_${widget.resId}',
        );
        period = periods.firstWhere(
          (p) => p.name == remembered,
          orElse: () => periods.first,
        );
      }
      final video = period?.video ?? detail.video;
      if (video == null || video.storages.isEmpty) {
        throw StateError('该课程没有可播放的视频');
      }
      proxy_.register(widget.resId, video.storages);
      debugPrint('registered ${video.storages.length} mirrors');
      final proxy = proxy_;

      final entry = appController.watchEntryOf(widget.resId);
      _resumeAt =
          entry != null && entry.positionSec > 30 && entry.durationSec <= 0
          ? null
          : (entry != null && entry.positionSec > 30
                ? entry.positionSec
                : null);

      final player = Player(
        configuration: const PlayerConfiguration(bufferSize: 32 * 1024 * 1024),
      );
      final native = player.platform;
      if (native is NativePlayer) {
        // Linux + NVIDIA: auto-safe resolves to nvdec, whose CUDA-GL
        // interop segfaults libmpv inside cuGraphicsUnregisterResource on
        // video_output_dispose (AppImage crash, coredump on driver
        // 610.57.04). Copy modes still decode on the GPU but never
        // register CUDA-GL interop resources. macOS (videotoolbox) and
        // Windows (d3d11va) keep auto-safe.
        await native.setProperty(
          'hwdec',
          Platform.isLinux ? 'auto-copy' : 'auto-safe',
        );
        await native.setProperty('cache-pause', 'no');
      }
      final controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          // Linux: Flutter's desktop renderer cannot composite media_kit's
          // GL external texture (solid-blue video area; the GDK GL context
          // mpv renders into is invisible to Impeller). Pixel-buffer
          // (MPV_RENDER_API_TYPE_SW) textures upload like any other image
          // and render on every backend; hwdec=auto-copy above still decodes
          // on the GPU. Other platforms keep GPU compositing.
          enableHardwareAcceleration: !Platform.isLinux,
        ),
      );

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
        _period = period;
        _loading = false;
      });
      // Quit arbiter (main.dart): this page owns the live mpv player and
      // its registered texture until the route pops.
      appController.activeTeardown = _disposeActivePlayer;
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

  /// Switch the playing 备课课时 in place: re-register the period's mirrors
  /// under the same resource id and reopen the (rewritten) playlist.
  Future<void> _switchPeriod(LessonPeriod p) async {
    final player = _player;
    final video = p.video;
    if (player == null || video == null || _period?.name == p.name) return;
    final proxy = context.read<StreamProxy>();
    proxy.register(widget.resId, video.storages);
    setState(() {
      _period = p;
      _recorded = false;
      _lastRecorded = Duration.zero;
    });
    unawaited(
      (await SharedPreferences.getInstance()).setString(
        'hc_lesson_period_${widget.resId}',
        p.name,
      ),
    );
    await player.open(Media(proxy.playlistUrl(widget.resId).toString()));
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
      title: _period == null
          ? (_detail?.title ?? widget.title)
          : '${_detail?.title ?? widget.title} · ${_period!.name}',
      tmId: widget.tmId ?? _appController?.material?.id ?? '',
      positionSec: pos.inMilliseconds / 1000,
      durationSec: dur.inMilliseconds / 1000,
      coverUrl: _appController?.coverUrlOf(widget.resId)?.toString(),
    );
  }

  @override
  void dispose() {
    unawaited(_disposeActivePlayer());
    _positionSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  /// Deterministic player teardown shared by route pop, retry-reload and
  /// the quit arbiter: stop() first so mpv render callbacks cease, then
  /// dispose() which unregisters the texture. Concurrent callers join one
  /// in-flight job instead of disposing twice.
  Future<void> _disposeActivePlayer() {
    final inFlight = _disposeJob;
    if (inFlight != null) return inFlight;
    final player = _player;
    if (player == null) return Future.value();
    _player = null;
    return _disposeJob = () async {
      try {
        await player.stop();
      } catch (_) {}
      try {
        await player.dispose();
      } catch (_) {}
    }().whenComplete(() => _disposeJob = null);
  }

  @override
  Widget build(BuildContext context) {
    final wide = HcLayout.twoPane(context, minWidth: 840);
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
              unawaited(_disposeActivePlayer());
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
                width:
                    (MediaQuery.sizeOf(context).width * 0.42).clamp(280.0, 360.0),
                child: _buildSidebar(context),
              ),
            ],
          )
        : Column(
            // Portrait: the video takes its natural 16:9 height from
            // the screen width; a fixed flex split left huge black
            // bands inside the video area and squeezed the info
            // section (title/resources) into the bottom quarter.
            children: [
              _buildVideo(context),
              Expanded(child: _buildBelow(context)),
            ],
          );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _detail?.title ?? widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
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
          controls: (state) =>
              _HuichuangControls(state: state, isDesktop: _isDesktop),
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
        controls: (state) =>
            _HuichuangControls(state: state, isDesktop: _isDesktop),
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    final d = _detail;
    if (d == null) return const SizedBox.shrink();
    final periods = d.periods;
    final multi = periods.length >= 2;
    final flatDocs = d.related.where((r) => !r.isVideo).toList();

    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
              ],
            ),
          ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '课时'),
              Tab(text: '附件'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                // ---- 课时: the pack's periods, or — for an undivided
                // course — a single entry named after the course itself
                multi
                    ? ListView(
                        children: [
                          for (final p in periods)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ListTile(
                                  dense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  selected: _period?.name == p.name,
                                  selectedTileColor: Theme.of(
                                    context,
                                  ).colorScheme.secondaryContainer,
                                  leading: Icon(
                                    Icons.play_circle_outline,
                                    size: 20,
                                    color: _period?.name == p.name
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context).colorScheme.outline,
                                  ),
                                  title: Text(
                                    p.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  onTap: _period?.name == p.name
                                      ? null
                                      : () => _switchPeriod(p),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 16,
                                    right: 16,
                                    top: 8,
                                    bottom: 4,
                                  ),
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      for (final doc in p.docs)
                                        _docChip(context, doc),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1, indent: 16),
                              ],
                            ),
                        ],
                      )
                    : ListView(
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                selected: true,
                                selectedTileColor: Theme.of(
                                  context,
                                ).colorScheme.secondaryContainer,
                                leading: Icon(
                                  Icons.play_circle_outline,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                title: Text(
                                  d.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 16,
                                  right: 16,
                                  top: 8,
                                  bottom: 4,
                                ),
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final doc in flatDocs)
                                      _docChip(context, doc),
                                  ],
                                ),
                              ),
                              const Divider(height: 1, indent: 16),
                            ],
                          ),
                        ],
                      ),
                // ---- 附件: every period's resources, divider per period
                ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (multi)
                      for (final p in periods) ...[
                        Row(
                          children: [
                            const Expanded(child: Divider()),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Text(
                                p.name,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outline,
                                    ),
                              ),
                            ),
                            const Expanded(child: Divider()),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final doc in p.docs)
                                _docChip(
                                  context,
                                  doc,
                                  iconSize: 18,
                                  fontSize: 14,
                                ),
                            ],
                          ),
                        ),
                      ]
                    else if (flatDocs.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final doc in flatDocs)
                            _docChip(context, doc, iconSize: 18, fontSize: 14),
                        ],
                      )
                    else
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text('无附件'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBelow(BuildContext context) {
    final d = _detail;
    if (d == null) return const SizedBox.shrink();
    final periods = d.periods;
    final multi = periods.length >= 2;
    final docs = multi
        ? (_period?.docs ?? const <RelatedResource>[])
        : d.related.where((r) => !r.isVideo).toList();

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
                ],
              ),
            ),
          ],
        ),
        if (multi)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 8,
              children: [
                for (final p in periods)
                  ChoiceChip(
                    label: Text(p.name),
                    selected: _period?.name == p.name,
                    onSelected: (_) => _switchPeriod(p),
                  ),
              ],
            ),
          ),
        if (docs.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            '课时资源',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final doc in docs)
                _docChip(context, doc, iconSize: 18, fontSize: 14),
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

  /// Attachment chip for a lesson doc; opens it through [_openDoc].
  Widget _docChip(
    BuildContext context,
    RelatedResource doc, {
    double iconSize = 16,
    double fontSize = 12,
  }) {
    return ActionChip(
      avatar: Icon(
        _iconFor(doc.format),
        size: iconSize,
        color: Theme.of(context).colorScheme.primary,
      ),
      label: Text(
        doc.typeName ?? doc.format ?? doc.title,
        style: TextStyle(fontSize: fontSize),
      ),
      onPressed: () => _openDoc(context, doc),
    );
  }

  Future<void> _openDoc(BuildContext context, RelatedResource doc) async {
    if (doc.storages.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该资源没有可用文件')));
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('正在下载 ${doc.title} …')));
    try {
      final client = HttpClient();
      final req = await client.getUrl(url);
      final res = await req.close();
      final name =
          '${doc.title}.${(doc.format ?? 'bin').replaceAll(RegExp(r'[^a-z0-9]'), '')}';
      final dir = _isDesktop ? Directory.systemTemp : await _mobileDownloads();
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
        final args = Platform.isWindows
            ? ['/c', 'start', '', file.path]
            : [file.path];
        await Process.run(opener, args);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('已保存到 ${file.path}')));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载失败：$e')));
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
          Icon(
            Icons.error_outline,
            size: 44,
            color: Theme.of(context).colorScheme.error,
          ),
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
              : FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// Custom control bar: mouse + touch, keyboard shortcuts, drag gestures.
class _HuichuangControls extends StatefulWidget {
  const _HuichuangControls({required this.state, required this.isDesktop});

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

  /// Double-tap zone handling: null = none yet, -1 = left (back 10s),
  /// +1 = right (forward 10s).
  double? _doubleTapDx;
  int? _seekFlash;
  Timer? _seekFlashTimer;

  Player get _player => widget.state.widget.controller.player;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _seekFlashTimer?.cancel();
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

  /// Mobile double-tap zones: left third -10s, right third +10s (with a
  /// flash bubble), center (and any desktop double-click) toggles
  /// fullscreen — the common mobile video-player contract.
  Future<void> _onDoubleTap() async {
    final dx = _doubleTapDx;
    final width = MediaQuery.sizeOf(context).width;
    final zone = dx == null ? 0 : (dx < width / 3 ? -1 : dx > width * 2 / 3 ? 1 : 0);
    if (widget.isDesktop || zone == 0) {
      await _toggleFullscreen();
      return;
    }
    await _seekBy(zone * 10);
    setState(() => _seekFlash = zone);
    _seekFlashTimer?.cancel();
    _seekFlashTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _seekFlash = null);
    });
  }

  Future<void> _toggleFullscreen() async {
    if (widget.isDesktop) {
      final isFs = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!isFs);
    } else {
      final route = FullscreenVideoRoute(
        child: _ImmersiveScope(
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Center(child: widget.state.widget),
          ),
        ),
      );
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
    if (!_draggingSeek &&
        !_draggingVolume &&
        dx.abs() > dy.abs() &&
        dx.abs() > 14) {
      _draggingSeek = true;
    } else if (!_draggingSeek &&
        !_draggingVolume &&
        dy.abs() > 14 &&
        e.position.dx > MediaQuery.sizeOf(context).width / 2) {
      _draggingVolume = true;
    }
    if (_draggingSeek) {
      final width = MediaQuery.sizeOf(context).width;
      final deltaSec =
          (dx / width) *
          (widget.state.widget.controller.player.state.duration.inSeconds.clamp(
            60,
            600,
          )) *
          2;
      _dragPreview = _seekBase + Duration(seconds: deltaSec.round());
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
              onDoubleTapDown: (d) => _doubleTapDx = d.globalPosition.dx,
              onDoubleTap: _onDoubleTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Progress-independent overlays.
                  if (_dragPreview != null)
                    _dragOverlay('$_fmtDur(_dragPreview!)'),
                  if (_volumePreview != null)
                    _dragOverlay('音量 ${_volumePreview!.round()}%'),
                  if (_seekFlash != null)
                    Align(
                      alignment: _seekFlash! < 0
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 36),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            _seekFlash! < 0
                                ? Icons.replay_10
                                : Icons.forward_10,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
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
                              horizontal: 16,
                              vertical: 8,
                            ),
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
                                      icon: const Icon(
                                        Icons.replay_10,
                                        color: Colors.white,
                                      ),
                                      onPressed: () => _seekBy(-10),
                                    ),
                                    IconButton(
                                      tooltip: '前进 10 秒 (→)',
                                      icon: const Icon(
                                        Icons.forward_10,
                                        color: Colors.white,
                                      ),
                                      onPressed: () => _seekBy(10),
                                    ),
                                    Flexible(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                        ),
                                        child: Text(
                                          '${_fmtDur(position)} / ${_fmtDur(duration)}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    if (widget.isDesktop)
                                      _VolumeControl(player: media),
                                    PopupMenuButton<double>(
                                      tooltip: '倍速',
                                      initialValue: _speed,
                                      onSelected: _setSpeed,
                                      itemBuilder: (_) => [
                                        for (final s in const [
                                          0.5,
                                          0.75,
                                          1.0,
                                          1.25,
                                          1.5,
                                          2.0,
                                        ])
                                          PopupMenuItem(
                                            value: s,
                                            child: Text(
                                              s == 1.0 ? '正常' : '$s×',
                                            ),
                                          ),
                                      ],
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                        ),
                                        child: Text(
                                          _speed == 1.0 ? '倍速' : '$_speed×',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '全屏 (F)',
                                      icon: const Icon(
                                        Icons.fullscreen,
                                        color: Colors.white,
                                      ),
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
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
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
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
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
    final value = total <= 0 ? 0.0 : (_dragging ? _dragValue : pos / total);
    final bufferedEnd = total <= 0
        ? 0.0
        : widget.bufferedEnd.inMilliseconds / total;

    return LayoutBuilder(
      builder: (context, constraints) {
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
              _dragValue = (_dragValue + d.delta.dx / width).clamp(0.0, 1.0);
            });
          },
          onHorizontalDragEnd: (_) async {
            await widget.onSeek(
              Duration(milliseconds: (_dragValue * total).round()),
            );
            setState(() => _dragging = false);
          },
          onTapUp: (d) async {
            final frac = (d.localPosition.dx / width).clamp(0.0, 1.0);
            await widget.onSeek(Duration(milliseconds: (frac * total).round()));
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
                    valueColor: const AlwaysStoppedAnimation(Colors.white38),
                  ),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: value.clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: Colors.transparent,
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF5B8DEF)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
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

/// Mobile fullscreen means fullscreen: hide the status/navigation bars,
/// lock landscape so a 16:9 picture fills the screen, and restore both
/// when the route pops (dispose also runs on back gesture / pop).
class _ImmersiveScope extends StatefulWidget {
  const _ImmersiveScope({required this.child});

  final Widget child;

  @override
  State<_ImmersiveScope> createState() => _ImmersiveScopeState();
}

class _ImmersiveScopeState extends State<_ImmersiveScope> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    // Flutter's default on Android; other modes require an app-wide
    // migration, so restore exactly this.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
