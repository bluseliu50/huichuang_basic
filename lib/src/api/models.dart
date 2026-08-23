/// Data models for the 国家中小学智慧教育平台 (basic.smartedu.cn) APIs.
///
/// All shapes verified against live JSON responses (2026-08 session);
/// parsing is defensive: unknown/missing fields never throw.
library;

import 'dart:convert';

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

Map<String, dynamic> _decodeObject(String s) {
  final d = jsonDecode(s);
  if (d is Map) return d.cast<String, dynamic>();
  throw const FormatException('expected JSON object');
}

class TagNode {
  const TagNode({
    required this.id,
    required this.name,
    this.dimensionId,
    this.children = const [],
  });

  final String id;
  final String name;
  final String? dimensionId;
  final List<TagNode> children;

  factory TagNode.fromJson(Map<String, dynamic> j) {
    final nested =
        (j['hierarchies'] as List?)?.cast<Map>().firstOrNull?['children']
                as List? ??
            const [];
    return TagNode(
      id: j['tag_id'] as String? ?? '',
      name: j['tag_name'] as String? ?? '',
      dimensionId: j['tag_dimension_id'] as String?,
      children: nested
          .cast<Map>()
          .map((c) => TagNode.fromJson(c.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }
}

/// Full tag tree for 课程教学: 学段 → 年级 → 学科 → 版本 → 册次 → 新旧教材.
class TagTree {
  const TagTree({required this.roots});

  final List<TagNode> roots;

  factory TagTree.fromJson(Map<String, dynamic> j) {
    final children =
        (j['hierarchies'] as List?)?.cast<Map>().firstOrNull?['children']
                as List? ??
            const [];
    return TagTree(
      roots: children
          .cast<Map>()
          .map((c) => TagNode.fromJson(c.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }
}

class TeachingMaterial {
  const TeachingMaterial({
    required this.id,
    required this.title,
    required this.tags,
    required this.tagIds,
  });

  final String id;
  final String title;

  /// tag_dimension_id → tag_name (e.g. `zxxxd` → `小学`).
  final Map<String, String> tags;

  /// tag_dimension_id → tag_id.
  final Map<String, String> tagIds;

  static Map<String, String> _tagMap(
      Map<String, dynamic> j, String valueKey) {
    final out = <String, String>{};
    for (final t in (j['tag_list'] as List? ?? const []).cast<Map>()) {
      final dim = t['tag_dimension_id'] as String?;
      final val = t[valueKey] as String?;
      if (dim != null && val != null) out[dim] = val;
    }
    return out;
  }

  factory TeachingMaterial.fromJson(Map<String, dynamic> j) =>
      TeachingMaterial(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        tags: _tagMap(j, 'tag_name'),
        tagIds: _tagMap(j, 'tag_id'),
      );

  String? tag(String dim) => tags[dim];
}

class ChapterNode {
  const ChapterNode({
    required this.id,
    required this.title,
    this.children,
  });

  final String id;
  final String title;
  final List<ChapterNode>? children;

  factory ChapterNode.fromJson(Map<String, dynamic> j) {
    final raw = j['child_nodes'];
    List<ChapterNode>? kids;
    if (raw is List && raw.isNotEmpty) {
      kids = raw
          .cast<Map>()
          .map((c) => ChapterNode.fromJson(c.cast<String, dynamic>()))
          .toList(growable: false);
    }
    return ChapterNode(
      id: j['id'] as String? ?? '',
      title: j['title'] as String? ?? '',
      children: kids,
    );
  }
}

/// One lesson entry of a teaching material's resource list.
class Lesson {
  const Lesson({
    required this.id,
    required this.title,
    required this.tags,
    required this.chapterIds,
    this.isCoursePackage = false,
  });

  final String id;
  final String title;
  final Map<String, String> tags;

  /// Ancestry in the chapter tree, root first; the last id is the leaf
  /// chapter this lesson belongs to.
  final List<String> chapterIds;

  /// `bklx` == 课程包 marks the packaged course (video + 课件 + …).
  final bool isCoursePackage;

  factory Lesson.fromJson(Map<String, dynamic> j) {
    final tags = TeachingMaterial._tagMap(j, 'tag_name');
    return Lesson(
      id: j['id'] as String? ?? '',
      title: j['title'] as String? ?? '',
      tags: tags,
      chapterIds: (j['chapter_ids'] as List? ?? const [])
          .map((e) => e as String)
          .toList(growable: false),
      isCoursePackage: tags['bklx'] == '课程包',
    );
  }

  String? get week => tags['zxxweek'];
}

/// A single downloadable/streamable item inside a lesson's resource pack
/// (视频 m3u8, 课件 pdf, 教学设计 docx, …).
class RelatedResource {
  const RelatedResource({
    required this.id,
    required this.title,
    required this.format,
    required this.storages,
    this.typeName,
    this.coverUrl,
  });

  final String id;
  final String title;
  final String? format; // m3u8 | pdf | ppt | doc | …
  final List<Uri> storages; // r1/r2/r3 mirrors, in preference order
  final String? typeName; // 微课视频 / 课件 / 教学设计 / …
  final Uri? coverUrl; // jpg cover embedded in the same pack (video entries)

  bool get isVideo => format == 'm3u8';

  factory RelatedResource.fromJson(Map<String, dynamic> j) {
    final items = (j['ti_items'] as List? ?? const []).cast<Map>();
    // The format of the first item that has one drives this resource; packs
    // may also embed covers (jpg) which must not leak into storages.
    final format = items
        .map((t) => t['ti_format'] as String?)
        .firstWhere((f) => f != null && f.isNotEmpty, orElse: () => null);
    final storages = <Uri>[];
    Uri? cover;
    for (final item in items) {
      final f = item['ti_format'] as String?;
      if (f != format) {
        if (f == 'jpg' && cover == null) {
          final first =
              (item['ti_storages'] as List? ?? const []).firstOrNull as String?;
          if (first != null && first.isNotEmpty) cover = Uri.parse(first);
        }
        continue;
      }
      for (final s in (item['ti_storages'] as List? ?? const [])) {
        final u = s as String?;
        if (u != null && u.isNotEmpty) storages.add(Uri.parse(u));
      }
    }
    return RelatedResource(
      id: j['id'] as String? ?? '',
      title: j['title'] as String? ?? '',
      format: format,
      storages: storages,
      typeName: j['resource_type_code_name'] as String?,
      coverUrl: cover,
    );
  }

  /// tch_material (电子教材) details carry `ti_items` at the root instead of
  /// a relations map; formats are mixed (txt / folder / pdf / jpg), so group
  /// storages by format into one resource each.
  static List<RelatedResource> fromRootItems(Map<String, dynamic> j) {
    final byFormat = <String, List<Uri>>{};
    Uri? cover;
    for (final item in (j['ti_items'] as List? ?? const []).cast<Map>()) {
      final f = item['ti_format'] as String? ?? '';
      for (final s in (item['ti_storages'] as List? ?? const [])) {
        final u = s as String?;
        if (u == null || u.isEmpty) continue;
        final uri = Uri.parse(u);
        if (f == 'jpg') {
          cover ??= uri;
        } else {
          byFormat.putIfAbsent(f, () => []).add(uri);
        }
      }
    }
    return [
      for (final e in byFormat.entries)
        RelatedResource(
          id: j['id'] as String? ?? '',
          title: j['title'] as String? ?? '',
          format: e.key,
          storages: e.value,
          coverUrl: cover,
        ),
    ];
  }
}

class ResourceDetail {
  const ResourceDetail({
    required this.id,
    required this.title,
    required this.related,
    this.teachers = const [],
    this.provider,
    this.durationSeconds,
  });

  final String id;
  final String title;
  final List<RelatedResource> related;
  final List<String> teachers;
  final String? provider;
  final int? durationSeconds; // custom_properties.study_time

  /// The playable video item, if present.
  RelatedResource? get video {
    for (final r in related) {
      if (r.isVideo) return r;
    }
    return null;
  }

  /// `global_title` may be `{"zh-CN": "…"}` or a plain string.
  static String? _localizedTitle(dynamic v) {
    if (v is String) return v;
    if (v is Map) {
      return v['zh-CN'] as String? ??
          (v.values.isEmpty ? null : v.values.first as String?);
    }
    return null;
  }
  factory ResourceDetail.fromJson(Map<String, dynamic> j) {
    var related = ((j['relations'] as Map?)?['national_course_resource']
                as List? ??
            const [])
        .cast<Map>()
        .map((m) => RelatedResource.fromJson(m.cast<String, dynamic>()))
        .where((r) => r.storages.isNotEmpty || r.isVideo)
        .toList(growable: false);
    if (related.isEmpty) {
      // 电子教材 details have no relations map; ti_items live at the root.
      related = RelatedResource.fromRootItems(j);
    }

    String? provider;
    final providers = (j['provider_list'] as List?)?.cast<Map>();
    if (providers != null && providers.isNotEmpty) {
      provider = providers.first['name'] as String?;
    }

    final custom = j['custom_properties'] as Map?;
    final studyTime = custom?['study_time'];

    return ResourceDetail(
      id: j['id'] as String? ?? '',
      title: _localizedTitle(j['global_title']) ?? j['title'] as String? ?? '',
      related: related,
      teachers: (j['teacher_list'] as List? ?? const [])
          .cast<Map>()
          .map((t) => t['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList(growable: false),
      provider: provider,
      durationSeconds: studyTime is int ? studyTime : null,
    );
  }
}

class UserInfo {
  const UserInfo({required this.userId, required this.name, this.avatarUrl});

  final String userId;
  final String name;
  final String? avatarUrl;
}

/// Auth bundle held by the app (from WebView login capture or refresh).
class TokenBundle {
  const TokenBundle({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.macKey,
    required this.expiresAt,
    this.diff = 0,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
  final String macKey;
  final int expiresAt;

  /// Local↔server clock skew in ms (from UC server).
  final int diff;

  bool needsRefresh(int nowMs, {int thresholdMs = 48 * 3600 * 1000}) =>
      expiresAt - nowMs < thresholdMs;

  bool get isExpired =>
      expiresAt <= DateTime.now().millisecondsSinceEpoch;

  /// Inner UC json (flat access_token / refresh_token / …) — the shape both
  /// the login localStorage capture and the refresh endpoint produce.
  factory TokenBundle.fromUcJson(Map<String, dynamic> j) => TokenBundle(
        accessToken: j['access_token'] as String? ?? '',
        refreshToken: j['refresh_token'] as String? ?? '',
        userId: (j['user_id'] ?? j['account_id'] ?? '').toString(),
        macKey: j['mac_key'] as String? ?? '',
        expiresAt: j['expires_at'] is int
            ? j['expires_at'] as int
            : DateTime.parse(j['expires_at'] as String? ?? '')
                .millisecondsSinceEpoch,
        diff: j['diff'] is int ? j['diff'] as int : 0,
      );

  /// localStorage raw value: `{"value":"<json string>","expire":…}`.
  factory TokenBundle.fromLocalStorage(String raw) {
    final outer = _decodeObject(raw);
    final value = outer['value'];
    final inner = value is String
        ? _decodeObject(value)
        : (value as Map? ?? const {}).cast<String, dynamic>();
    return TokenBundle.fromUcJson(inner);
  }

  Map<String, dynamic> toUcJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'user_id': userId,
        'mac_key': macKey,
        'expires_at': expiresAt,
        'diff': diff,
      };
}
