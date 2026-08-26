/// HTTP client for basic.smartedu.cn endpoints.
///
/// Static catalog JSON lives on s-file-1/s-file-2 (mirror pair, no auth);
/// auth flows go through uc-gateway. Node failover + retries are built in —
/// resilience here is part of the "video always plays" goal.
library;

import 'package:dio/dio.dart';

import 'models.dart';

class SmarteduApiException implements Exception {
  const SmarteduApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'SmarteduApiException($statusCode): $message';
}

class SmarteduClient {
  SmarteduClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: {'accept': 'application/json'},
            ));

  static const List<String> fileHosts = [
    's-file-1.ykt.cbern.com.cn',
    's-file-2.ykt.cbern.com.cn',
  ];

  static const String ucBase = 'https://uc-gateway.ykt.eduyun.cn';

  /// sdp-app-id of the 中小学 client (verified from live traffic).
  static const String sdpAppId = 'e5649925-441d-4a53-b525-51a2f1c4e0a8';

  final Dio _dio;

  /// GET a catalog JSON, failing over s-file-1 ↔ s-file-2 (2 rounds).
  Future<dynamic> getFileJson(String path,
      {Map<String, String>? query}) async {
    Object? lastError;
    for (var round = 0; round < 2; round++) {
      for (final host in fileHosts) {
        try {
          final res = await _dio.get<dynamic>('https://$host/zxx/$path',
              queryParameters: query);
          return res.data;
        } on DioException catch (e) {
          final status = e.response?.statusCode;
          if (status == 404) {
            // Both mirrors serve identical content; a 404 is real.
            throw SmarteduApiException('not found: $path', statusCode: 404);
          }
          lastError = e;
        }
      }
    }
    throw SmarteduApiException('network error: $path ($lastError)');
  }

  Future<TagTree> getTagTree() async =>
      TagTree.fromJson((await getFileJson('ndrs/tags/national_lesson_tag.json'))
          as Map<String, dynamic>);

  /// module_version of the teaching-materials dataset (cache invalidation).
  Future<int> getMaterialsVersion() async {
    final v = (await getFileJson(
        'ndrs/national_lesson/teachingmaterials/version/data_version.json'))
        as Map<String, dynamic>;
    return v['module_version'] as int? ?? 0;
  }

  Future<List<TeachingMaterial>> getMaterials() async {
    final out = <TeachingMaterial>[];
    for (final part in const [100, 101, 102]) {
      final data = await getFileJson(
          'ndrs/national_lesson/teachingmaterials/part_$part.json');
      for (final m in (data as List).cast<Map>()) {
        out.add(TeachingMaterial.fromJson(m.cast<String, dynamic>()));
      }
    }
    return out;
  }

  Future<List<ChapterNode>> getChapterTree(String tmId) async {
    final data = await getFileJson(
        'ndrv2/national_lesson/trees/$tmId.json');
    return (data as List)
        .cast<Map>()
        .map((m) => ChapterNode.fromJson(m.cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<List<Lesson>> getLessons(String tmId) async {
    final data = await getFileJson(
        'ndrs/national_lesson/teachingmaterials/$tmId/resources/part_100.json');
    return (data as List)
        .cast<Map>()
        .map((m) => Lesson.fromJson(m.cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<ResourceDetail> getResourceDetail(String resId) async {
    dynamic data;
    try {
      data = await getFileJson(
          'ndrv2/national_lesson/resources/details/$resId.json');
    } on SmarteduApiException {
      // Non-course-pack lessons (吟唱 songs like 浪淘沙（其七）) live in a
      // parallel "singing" endpoint family: the national_lesson path 403s
      // for them, while their details are public under ndrv2/singing.
      // Their ti_items sit at the root (m3u8 + cover), which
      // ResourceDetail.fromJson already parses via fromRootItems.
      data = await getFileJson('ndrv2/singing/resources/details/$resId.json');
    }
    return ResourceDetail.fromJson(data as Map<String, dynamic>);
  }

  /// Textbook (tch_material) detail for the PDF reader.
  Future<ResourceDetail> getTextbookDetail(String contentId) async {
    final data = await getFileJson(
        'ndrv2/resources/tch_material/details/$contentId.json');
    return ResourceDetail.fromJson(data as Map<String, dynamic>);
  }

  /// Refresh the token pair. No auth header needed; rotates both tokens.
  /// Verified live: 201 with flat token json.
  static Future<TokenBundle> refreshToken(String refreshToken,
      {Dio? dio}) async {
    final client = dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ));
    try {
      final res = await client.post<dynamic>(
        '$ucBase/v1.1/tokens/$refreshToken/actions/refresh',
      );
      final data = res.data;
      if (data is Map<String, dynamic>) {
        return TokenBundle.fromUcJson(data);
      }
      throw const SmarteduApiException('refresh: unexpected body');
    } on DioException catch (e) {
      throw SmarteduApiException('refresh failed: ${e.message}',
          statusCode: e.response?.statusCode);
    }
  }

  Future<UserInfo?> getUserInfo(TokenBundle token) async {
    try {
      final res = await _dio.get<dynamic>(
        '$ucBase/v1.1/users/${token.userId}',
        queryParameters: {
          'with_ext': 'true',
          'session_id': token.accessToken,
        },
      );
      final data = res.data;
      if (data is Map<String, dynamic>) {
        final name = data['real_name'] as String?;
        final avatar = data['avatar'] as String?;
        final id = (data['user_id'] ?? data['account_id'] ?? token.userId)
            .toString();
        return UserInfo(
            userId: id, name: name ?? '用户$id', avatarUrl: avatar);
      }
      return null;
    } on DioException {
      return null;
    }
  }
}
