/// Catalog service: tag tree + teaching materials with a disk cache
/// invalidated by the platform's `module_version`.
library;

import 'dart:convert';
import 'dart:io';

import 'client.dart';
import 'models.dart';

class CatalogService {
  CatalogService({required this.cacheDir, SmarteduClient? client})
      : _client = client ?? SmarteduClient();

  final Directory cacheDir;
  final SmarteduClient _client;

  TagTree? _tagTree;
  List<TeachingMaterial>? _materials;
  Map<String, List<TeachingMaterial>> _byStage = const {};

  TagTree? get tagTree => _tagTree;
  List<TeachingMaterial>? get materials => _materials;

  File _f(String name) => File('${cacheDir.path}/$name');

  Future<String?> _readCached(String name) async {
    try {
      return await _f(name).readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String name, String body) async {
    try {
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      await _f(name).writeAsString(body);
    } catch (_) {
      // Cache write failures are non-fatal.
    }
  }

  /// Loads tag tree + materials, using the disk cache when the platform
  /// version is unchanged. Fresh data is fetched when versions differ or
  /// no cache exists; if the network fails, falls back to any cache.
  Future<void> load() async {
    final version = await _client.getMaterialsVersion().catchError((_) => -1);
    final cachedVersion =
        int.tryParse(await _readCached('catalog_version.txt') ?? '') ?? -2;
    final wantFresh = version != cachedVersion;

    // --- tag tree ---
    final tagCached = await _readCached('tag_tree.json');
    String? tagRaw;
    if (wantFresh || tagCached == null) {
      try {
        tagRaw = jsonEncode(
            await _client.getFileJson('ndrs/tags/national_lesson_tag.json'));
        await _writeCache('tag_tree.json', tagRaw);
      } catch (_) {
        tagRaw = tagCached;
      }
    } else {
      tagRaw = tagCached;
    }
    if (tagRaw != null) {
      _tagTree =
          TagTree.fromJson(jsonDecode(tagRaw) as Map<String, dynamic>);
    }

    // --- materials ---
    final matsCached = await _readCached('materials.json');
    List<TeachingMaterial>? mats;
    if (wantFresh || matsCached == null) {
      try {
        mats = await _client.getMaterials();
        await _writeCache('materials.json', jsonEncode([
          for (final m in mats)
            {
              'id': m.id,
              'title': m.title,
              'tag_list': [
                for (final e in m.tags.entries)
                  {
                    'tag_dimension_id': e.key,
                    'tag_name': e.value,
                    'tag_id': m.tagIds[e.key],
                  },
              ],
            },
        ]));
      } catch (_) {
        mats = null;
      }
    }
    mats ??= _decodeMaterials(matsCached);
    _materials = mats;

    if (version > 0) {
      await _writeCache('catalog_version.txt', '$version');
    }
    _reindex();
  }

  List<TeachingMaterial>? _decodeMaterials(String? cached) {
    if (cached == null) return null;
    try {
      final list = jsonDecode(cached) as List;
      return list
          .cast<Map>()
          .map((m) => TeachingMaterial.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  void _reindex() {
    final idx = <String, List<TeachingMaterial>>{};
    for (final m in _materials ?? const <TeachingMaterial>[]) {
      final stage = m.tagIds['zxxxd'];
      if (stage == null) continue;
      (idx[stage] ??= []).add(m);
    }
    _byStage = idx.map((k, v) => MapEntry(k, List.unmodifiable(v)));
  }

  List<TeachingMaterial> materialsForStage(String stageTagId) =>
      _byStage[stageTagId] ?? const [];

  /// Materials matching a tag selection (null dims are wildcards).
  List<TeachingMaterial> filter({
    required String stageId,
    String? gradeId,
    String? subjectId,
    String? editionId,
    String? volumeId,
    String? oldNewId,
  }) {
    Iterable<TeachingMaterial> pool = materialsForStage(stageId);
    bool keep(TeachingMaterial m, String? want, String dim) =>
        want == null || m.tagIds[dim] == want;
    return pool
        .where((m) =>
            keep(m, gradeId, 'zxxnj') &&
            keep(m, subjectId, 'zxxxk') &&
            keep(m, editionId, 'zxxbb') &&
            keep(m, volumeId, 'zxxcc') &&
            keep(m, oldNewId, 'zxxxjjc'))
        .toList(growable: false);
  }

  /// Case-insensitive substring search over cached material titles
  /// (remote x-search is WAF-blocked for non-browser clients — verified).
  List<TeachingMaterial> searchMaterials(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return (_materials ?? const <TeachingMaterial>[])
        .where((m) => m.title.toLowerCase().contains(q))
        .toList(growable: false);
  }

  TeachingMaterial? materialById(String id) {
    for (final m in _materials ?? const <TeachingMaterial>[]) {
      if (m.id == id) return m;
    }
    return null;
  }
}
