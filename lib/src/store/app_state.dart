/// App-wide UI state: catalog loading, tag selection, chapters & lessons,
/// watch history.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/catalog.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../stream/proxy.dart';

class Selection {
  const Selection({
    this.stageId,
    this.gradeId,
    this.subjectId,
    this.editionId,
    this.volumeId,
    this.oldNewId,
  });

  final String? stageId;
  final String? gradeId;
  final String? subjectId;
  final String? editionId;
  final String? volumeId;
  final String? oldNewId;

  Selection copyWith({
    String? stageId,
    bool clearStage = false,
    String? gradeId,
    bool clearGrade = false,
    String? subjectId,
    bool clearSubject = false,
    String? editionId,
    bool clearEdition = false,
    String? volumeId,
    bool clearVolume = false,
    String? oldNewId,
    bool clearOldNew = false,
  }) =>
      Selection(
        stageId: clearStage ? null : (stageId ?? this.stageId),
        gradeId: clearGrade ? null : (gradeId ?? this.gradeId),
        subjectId: clearSubject ? null : (subjectId ?? this.subjectId),
        editionId: clearEdition ? null : (editionId ?? this.editionId),
        volumeId: clearVolume ? null : (volumeId ?? this.volumeId),
        oldNewId: clearOldNew ? null : (oldNewId ?? this.oldNewId),
      );

  bool isValid(List<String> dims) =>
      stageId != null &&
      gradeId != null &&
      subjectId != null &&
      editionId != null &&
      volumeId != null;
}

enum LoadPhase { idle, loading, ready, error }

class WatchEntry {
  const WatchEntry({
    required this.resId,
    required this.title,
    required this.tmId,
    required this.positionSec,
    required this.durationSec,
    this.coverUrl,
    required this.updatedAt,
  });

  final String resId;
  final String title;
  final String tmId;
  final double positionSec;
  final double durationSec;
  final String? coverUrl;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
        'resId': resId,
        'title': title,
        'tmId': tmId,
        'positionSec': positionSec,
        'durationSec': durationSec,
        'coverUrl': coverUrl,
        'updatedAt': updatedAt,
      };

  factory WatchEntry.fromJson(Map<String, dynamic> j) => WatchEntry(
        resId: j['resId'] as String? ?? '',
        title: j['title'] as String? ?? '',
        tmId: j['tmId'] as String? ?? '',
        positionSec: (j['positionSec'] as num?)?.toDouble() ?? 0,
        durationSec: (j['durationSec'] as num?)?.toDouble() ?? 0,
        coverUrl: j['coverUrl'] as String?,
        updatedAt: j['updatedAt'] as int? ?? 0,
      );
}

class AppController extends ChangeNotifier {
  AppController({required this.catalog, required this.client})
      : _settings = null;

  final CatalogService catalog;
  final SmarteduClient client;

  /// Set by main once the auth-injecting proxy is running.
  StreamProxy? proxy;
  SharedPreferences? _settings;

  /// Runs on window close BEFORE the engine tears down (wired by the quit
  /// arbiter in main.dart): the open page releases its native-backed
  /// resources — the media_kit player (mpv render callbacks + registered
  /// texture) or pdfium page loads — which abort the whole process when they
  /// race the shutdown.
  Future<void> Function()? activeTeardown;

  LoadPhase catalogPhase = LoadPhase.idle;
  String? catalogError;
  final Completer<void> _catalogLoadComplete = Completer<void>();

  /// Resolves when the catalog has loaded (successfully or not).
  Future<void> get catalogLoadComplete => _catalogLoadComplete.future;

  Selection selection = const Selection();
  TeachingMaterial? material;
  List<ChapterNode> chapters = const [];
  List<Lesson> lessons = const [];
  LoadPhase contentPhase = LoadPhase.idle;

  Map<String, List<Lesson>> _lessonsByChapter = {};
  List<WatchEntry> _history = [];

  List<WatchEntry> get history =>
      List.unmodifiable(_history..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));

  /// Loads catalog + persisted last selection; then chapter/lesson content.
  Future<void> bootstrap() async {
    _settings ??= await SharedPreferences.getInstance();
    _loadHistory();
    if (catalogPhase == LoadPhase.loading || catalogPhase == LoadPhase.ready) {
      return;
    }
    catalogPhase = LoadPhase.loading;
    notifyListeners();
    try {
      await catalog.load();
      catalogPhase = LoadPhase.ready;
      notifyListeners();
      await _restoreLastMaterial();
    } catch (e) {
      catalogError = e.toString();
      catalogPhase = LoadPhase.error;
      notifyListeners();
    }
    if (!_catalogLoadComplete.isCompleted) _catalogLoadComplete.complete();
  }

  Future<void> retryCatalog() async {
    catalogPhase = LoadPhase.idle;
    catalogError = null;
    notifyListeners();
    await bootstrap();
  }

  // ------------------------------------------------------------ selection

  void updateSelection(Selection next) {
    selection = next;
    // Remember the most recent grade so subject jumps default to it.
    final grade = next.gradeId;
    if (grade != null) _settings?.setString('hc_recent_grade', grade);
    notifyListeners();
    final stage = next.stageId;
    if (stage == null) return;
    final matches = catalog.filter(
      stageId: stage,
      gradeId: next.gradeId,
      subjectId: next.subjectId,
      editionId: next.editionId,
      volumeId: next.volumeId,
      oldNewId: next.oldNewId,
    );
    if (matches.length == 1) {
      openMaterial(matches.first);
    } else {
      material = null;
      chapters = const [];
      lessons = const [];
      contentPhase = LoadPhase.idle;
      notifyListeners();
    }
  }

  Future<void> openMaterial(TeachingMaterial m) async {
    material = m;
    contentPhase = LoadPhase.loading;
    notifyListeners();
    try {
      final tree = await client.getChapterTree(m.id);
      final lessonList = await client.getLessons(m.id);
      chapters = tree;
      lessons = lessonList;
      _lessonsByChapter = _indexLessons(tree, lessonList);
      contentPhase = LoadPhase.ready;
      _settings?.setString('hc_last_teachingmaterial', m.id);
      // Rebuild selection from the material tags.
      selection = Selection(
        stageId: m.tagIds['zxxxd'],
        gradeId: m.tagIds['zxxnj'],
        subjectId: m.tagIds['zxxxk'],
        editionId: m.tagIds['zxxbb'],
        volumeId: m.tagIds['zxxcc'],
        oldNewId: m.tagIds['zxxxjjc'],
      );
      _rememberSubjectSelection();
    } catch (e) {
      contentPhase = LoadPhase.error;
    }
    notifyListeners();
  }

  Future<void> _restoreLastMaterial() async {
    final lastId = _settings?.getString('hc_last_teachingmaterial');
    if (lastId == null) return;
    final m = catalog.materialById(lastId);
    if (m != null) {
      await openMaterial(m);
    }
  }

  // -------------------------------------------------------- subject memory

  static const _subjectPrefPrefix = 'hc_subject_sel_';

  /// Last-opened {stage, grade, edition, volume, oldNew} of a subject tag id,
  /// persisted so each subject remembers its grade & textbook edition.
  Map<String, String>? subjectSelectionOf(String subjectId) {
    final raw = _settings?.getString('$_subjectPrefPrefix$subjectId');
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return null;
    }
  }

  void _rememberSubjectSelection() {
    final s = selection;
    final subject = s.subjectId;
    if (subject == null) return;
    _settings?.setString('$_subjectPrefPrefix$subject', jsonEncode({
          if (s.stageId != null) 'stage': s.stageId!,
          if (s.gradeId != null) 'grade': s.gradeId!,
          if (s.editionId != null) 'edition': s.editionId!,
          if (s.volumeId != null) 'volume': s.volumeId!,
          if (s.oldNewId != null) 'oldNew': s.oldNewId!,
        }));
  }

  /// Jump straight to a subject, restoring its cached grade/edition/volume;
  /// without a subject-local cache the most recently used grade wins over
  /// the caller's fallback. Returns true when a material was opened.
  bool selectSubject({
    required String stageId,
    required String subjectId,
    String? fallbackGradeId,
  }) {
    final prefs = subjectSelectionOf(subjectId);
    final stage = prefs?['stage'] ?? stageId;
    var grade = prefs?['grade'];
    if (grade == null) {
      final recent = _settings?.getString('hc_recent_grade');
      if (recent != null && _gradeHasSubject(stage, recent, subjectId)) {
        grade = recent;
      }
    }
    updateSelection(Selection(
      stageId: stage,
      gradeId: grade ?? fallbackGradeId,
      subjectId: subjectId,
      editionId: prefs?['edition'],
      volumeId: prefs?['volume'],
      oldNewId: prefs?['oldNew'],
    ));
    return material != null;
  }

  bool _gradeHasSubject(String stageId, String gradeId, String subjectId) {
    for (final s in catalog.tagTree?.roots ?? const <TagNode>[]) {
      if (s.id != stageId) continue;
      for (final g in s.children) {
        if (g.id != gradeId) continue;
        for (final sub in g.children) {
          if (sub.id == subjectId) return true;
        }
      }
    }
    return false;
  }

  final Map<String, Uri?> _coverCache = {};

  /// Cover image for a lesson, resolved from the resource detail's
  /// embedded jpg; proxied when on the private CDN.
  Uri? coverUrlOf(String resId) {
    final cached = _coverCache[resId];
    if (cached != null) {
      return _maybeProxy(cached);
    }
    if (_coverCache.containsKey(resId)) return null; // in flight
    _coverCache[resId] = null;
    client.getResourceDetail(resId).then((d) {
      final video = d.video;
      final cover = video?.coverUrl;
      if (cover != null) {
        _coverCache[resId] = cover;
        notifyListeners();
      } else {
        _coverCache.remove(resId);
      }
    }).catchError((_) {
      _coverCache.remove(resId);
    });
    return null;
  }

  final Map<String, Uri?> _textbookCoverCache = {};

  /// Cover image for an 电子教材, from its detail's embedded jpg
  /// (ti_items); proxied when on the private CDN.
  Uri? textbookCoverOf(String contentId) {
    final cached = _textbookCoverCache[contentId];
    if (cached != null) {
      return _maybeProxy(cached);
    }
    if (_textbookCoverCache.containsKey(contentId)) return null; // in flight
    _textbookCoverCache[contentId] = null;
    client.getTextbookDetail(contentId).then((d) {
      Uri? cover;
      for (final r in d.related) {
        if (r.coverUrl != null) {
          cover = r.coverUrl;
          break;
        }
      }
      if (cover != null) {
        _textbookCoverCache[contentId] = cover;
        notifyListeners();
      } else {
        _textbookCoverCache.remove(contentId);
      }
    }).catchError((_) {
      _textbookCoverCache.remove(contentId);
    });
    return null;
  }

  Uri _maybeProxy(Uri u) => proxy != null && u.host.contains('-ndr-private')
      ? proxy!.fileUrl(u)
      : u;

  List<Lesson> lessonsFor(ChapterNode chapter) {
    final direct = _lessonsByChapter[chapter.id] ?? const <Lesson>[];
    return direct;
  }

  Map<String, List<Lesson>> _indexLessons(
      List<ChapterNode> tree, List<Lesson> all) {
    final chapterIds = <String>{};
    void walk(ChapterNode n) {
      chapterIds.add(n.id);
      n.children?.forEach(walk);
    }

    tree.forEach(walk);
    // Map each lesson to its leaf chapter (chapter_ids.last).
    final idx = <String, List<Lesson>>{};
    for (final l in all) {
      final leaf = l.chapterIds.isEmpty ? null : l.chapterIds.last;
      if (leaf == null) continue;
      idx.putIfAbsent(leaf, () => []).add(l);
    }
    return idx;
  }

  // ------------------------------------------------------------ history

  void _loadHistory() {
    final raw = _settings?.getString('hc_watch_history');
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _history = list
          .cast<Map>()
          .map((m) => WatchEntry.fromJson(m.cast<String, dynamic>()))
          .toList();
    } catch (_) {}
  }

  Future<void> recordWatch({
    required String resId,
    required String title,
    required String tmId,
    required double positionSec,
    required double durationSec,
    String? coverUrl,
  }) async {
    _history.removeWhere((e) => e.resId == resId);
    _history.add(WatchEntry(
      resId: resId,
      title: title,
      tmId: tmId,
      positionSec: positionSec,
      durationSec: durationSec,
      coverUrl: coverUrl,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    if (_history.length > 100) {
      _history = _history.sublist(_history.length - 100);
    }
    await _settings?.setString(
        'hc_watch_history', jsonEncode([for (final e in _history) e.toJson()]));
    notifyListeners();
  }

  WatchEntry? watchEntryOf(String resId) {
    for (final e in _history) {
      if (e.resId == resId) return e;
    }
    return null;
  }

  /// Hardware-decode preference mirrored into settings.
  bool get hwDecode => _settings?.getBool('hc_hw_decode') ?? true;
  Future<void> setHwDecode(bool v) async {
    await _settings?.setBool('hc_hw_decode', v);
    notifyListeners();
  }

  /// Removes temporary downloaded files (settings action).
  Future<void> clearTempDownloads() async {
    try {
      final dir = Directory.systemTemp;
      await for (final f in dir.list()) {
        if (f is File && f.path.contains('huichuang')) {
          await f.delete().catchError((_) => f);
        }
      }
    } catch (_) {}
  }

  Future<void> clearHistory() async {
    _history = const [];
    await _settings?.remove('hc_watch_history');
    notifyListeners();
  }

  /// Quit path: release whatever the open page registered in
  /// [activeTeardown]. Best-effort — a failing teardown must not block the
  /// window from closing.
  Future<void> teardownForQuit() async {
    final teardown = activeTeardown;
    activeTeardown = null;
    if (teardown == null) return;
    try {
      await teardown();
    } catch (_) {}
  }
}
