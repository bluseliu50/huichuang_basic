import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huichuang_basic/src/api/catalog.dart';
import 'package:huichuang_basic/src/api/client.dart';
import 'package:huichuang_basic/src/api/models.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('TagTree', () {
    test('parses cascading dimensions', () {
      final tree = TagTree.fromJson(fixture('tag_tree.json'));
      final xiaoxue =
          tree.roots.singleWhere((n) => n.name == '小学');
      final grade1 =
          xiaoxue.children.singleWhere((n) => n.name == '一年级');
      final yuwen = grade1.children.singleWhere((n) => n.name == '语文');
      final tb = yuwen.children.singleWhere((n) => n.name == '统编版');
      final shangce = tb.children.singleWhere((n) => n.name == '上册');
      expect(xiaoxue.dimensionId, 'zxxxd');
      expect(grade1.dimensionId, 'zxxnj');
      expect(yuwen.dimensionId, 'zxxxk');
      expect(tb.dimensionId, 'zxxbb');
      expect(shangce.dimensionId, 'zxxcc');
      expect(shangce.children, isNotEmpty);
      expect(shangce.children.first.dimensionId, 'zxxxjjc');
    });

    test('empty hierarchies do not throw', () {
      final node = TagNode.fromJson({'tag_id': 'x', 'tag_name': 'y'});
      expect(node.children, isEmpty);
    });
  });

  group('TeachingMaterial', () {
    test('indexes tags by dimension', () {
      final m = TeachingMaterial.fromJson(fixture('material.json'));
      expect(m.tags['zxxxd'], '小学');
      expect(m.tags['zxxxk'], '语文·书法练习指导');
      expect(m.tagIds['zxxxd'], isNotEmpty);
      expect(m.title, contains('苏少版'));
    });
  });

  group('Lesson', () {
    test('parses course package flag and week', () {
      final l = Lesson.fromJson(fixture('lesson.json'));
      expect(l.id, isNotEmpty);
      expect(l.title, '三年级上册学习导引');
      expect(l.isCoursePackage, isTrue);
      expect(l.week, '第一周');
    });
  });

  group('ResourceDetail', () {
    test('extracts video m3u8 storages', () {
      final d = ResourceDetail.fromJson(fixture('resource_detail.json'));
      expect(d.title, '大青树下的小学');
      final video = d.video;
      expect(video, isNotNull);
      expect(video!.isVideo, isTrue);
      expect(video.storages, isNotEmpty);
      // All mirrors are on the private CDN with https.
      for (final u in video.storages) {
        expect(u.scheme, 'https');
        expect(u.host, contains('-ndr-private.ykt.cbern.com.cn'));
        expect(u.path, endsWith('.m3u8'));
      }
      // Non-video resources present too (课件 pdf).
      expect(d.related.length, greaterThan(1));
      expect(d.related.any((r) => r.typeName == '课件'), isTrue);
    });

    test('study_time surfaces as durationSeconds', () {
      final d = ResourceDetail.fromJson(fixture('resource_detail.json'));
      expect(d.durationSeconds, 3600);
    });

    test('parses tch_material root ti_items into per-format resources', () {
      final d = ResourceDetail.fromJson(fixture('textbook_detail.json'));
      final pdf = d.related.where((r) => r.format == 'pdf').toList();
      expect(pdf, hasLength(1));
      for (final u in pdf.first.storages) {
        expect(u.host, contains('-ndr-private.ykt.cbern.com.cn'));
        expect(u.path, endsWith('.pdf'));
      }
      // Mixed sibling formats stay grouped but distinguishable.
      expect(d.related.map((r) => r.format), containsAll(['txt', 'folder']));
      expect(pdf.first.coverUrl, isNotNull); // jpg cover captured
    });

    test('doc packs report the embedded pdf, not the folder/superboard meta',
        () {
      // 课件/教学设计 packs list a transcode `folder` and a `superboard`
      // before the real file; the previewable format must win.
      final d = ResourceDetail.fromJson(fixture('resource_detail.json'));
      final courseware =
          d.related.where((r) => r.typeName == '课件').toList();
      expect(courseware, hasLength(1));
      expect(courseware.first.format, 'pdf');
      for (final u in courseware.first.storages) {
        expect(u.path, endsWith('.pdf'));
      }
    });

    group('periods', () {
      final d = ResourceDetail.fromJson(fixture('resource_detail_periods.json'));

      test('splits bkks-tagged packs into periods', () {
        final periods = d.periods;
        expect(periods.map((p) => p.name), ['第一课时', '第二课时']);
        for (final p in periods) {
          expect(p.video, isNotNull);
          expect(p.video!.isVideo, isTrue);
        }
      });

      test('docs follow their period — tagged directly, untagged by order',
          () {
        final periods = d.periods;
        for (final p in periods) {
          final kinds = p.docs.map((r) => r.typeName).toSet();
          // 课件/教学设计 are untagged: the n-th of a kind joins the n-th
          // period; 学习任务单/课后练习 carry bkks directly.
          expect(kinds, containsAll(['课件', '教学设计', '学习任务单', '课后练习']));
          expect(p.docs.length, 4);
        }
      });
      test('splits untagged 新教材 packs by video order', () {
        // 新教材 carries no bkks tags: 2 videos + 2 of each doc kind,
        // laid out period by period in relations order.
        final periods = ResourceDetail.fromJson(
                fixture('resource_detail_periods_untagged.json'))
            .periods;
        expect(periods.map((p) => p.name), ['第一课时', '第二课时']);
        for (final p in periods) {
          expect(p.video, isNotNull);
          expect(p.video!.isVideo, isTrue);
          // The n-th doc of each kind lands in the n-th period.
          expect(p.docs.map((r) => r.typeName).toSet(),
              {'课件', '教学设计', '学习任务单', '课后练习'});
        }
      });

      test('extra untagged docs clamp to the last period', () {
        // 2 videos, 3 课件: the third joins the last period instead of
        // crashing.
        final docs = List.generate(
          3,
          (i) => RelatedResource(
            id: 'd$i',
            title: '课件${i + 1}',
            format: 'folder',
            storages: [Uri.parse('https://x/folder$i')],
            typeName: '课件',
          ),
        );
        final videos = List.generate(
          2,
          (i) => RelatedResource(
            id: 'v$i',
            title: '视频${i + 1}',
            format: 'm3u8',
            storages: [Uri.parse('https://x/v$i.m3u8')],
          ),
        );
        final d = ResourceDetail(id: 'x', title: 'x', related: [...videos, ...docs]);
        final periods = d.periods;
        expect(periods, hasLength(2));
        expect(periods[0].docs, hasLength(1));
        expect(periods[1].docs, hasLength(2));
      });

      test('single-period packs yield no breakdown', () {
        expect(ResourceDetail.fromJson(fixture('resource_detail.json')).periods,
            isEmpty);
      });
    });
  });

  group('TokenBundle', () {
    test('parses double-wrapped localStorage value', () {
      const raw =
          '{"value":"{\\"access_token\\":\\"A112\\",\\"refresh_token\\":\\"R336\\",\\"expires_at\\":1787500000000,\\"user_id\\":\\"452652750197\\",\\"mac_key\\":\\"mk\\"}","expire":1787500000000}';
      final t = TokenBundle.fromLocalStorage(raw);
      expect(t.accessToken, 'A112');
      expect(t.refreshToken, 'R336');
      expect(t.userId, '452652750197');
      expect(t.expiresAt, 1787500000000);
    });

    test('parses flat refresh response and round-trips', () {
      final j = {
        'access_token': 'A2',
        'refresh_token': 'R2',
        'user_id': 42,
        'mac_key': 'k',
        'expires_at': 1787600000000,
        'diff': 1234,
      };
      final t = TokenBundle.fromUcJson(j);
      expect(t.userId, '42');
      expect(t.diff, 1234);
      expect(TokenBundle.fromUcJson(t.toUcJson()).accessToken, 'A2');
    });

    test('needsRefresh threshold', () {
      final t = TokenBundle(
        accessToken: 'a',
        refreshToken: 'r',
        userId: 'u',
        macKey: 'm',
        expiresAt: 1000000,
      );
      // 47h left (of 48h threshold) → refresh needed.
      expect(t.needsRefresh(1000000 - 47 * 3600 * 1000), isTrue);
      // 49h left → fine.
      expect(t.needsRefresh(1000000 - 49 * 3600 * 1000), isFalse);
    });
  });

  group('CatalogService', () {
    test('caches to disk and filters by tag path', () async {
      final dir = await Directory.systemTemp.createTemp('hc_catalog');
      final calls = <String>[];
      final client = _FakeClient(fixture('tag_tree.json'), fixture('material.json'), calls);
      final svc = CatalogService(cacheDir: dir, client: client);

      await svc.load();
      expect(calls, containsAll(['version', 'tagtree', 'materials']));
      expect(svc.tagTree!.roots.singleWhere((n) => n.name == '小学'),
          isNotNull);

      // Stage filter: the fixture material is 小学/六年级/书法/苏少版/下册.
      final xiaoxue = svc.tagTree!.roots.singleWhere((n) => n.name == '小学');
      final mats = svc.materialsForStage(xiaoxue.id);
      expect(mats, hasLength(1));

      final filtered = svc.filter(stageId: xiaoxue.id);
      expect(filtered, hasLength(1));

      // Second load with same version → served from cache (no refetch).
      calls.clear();
      final svc2 = CatalogService(cacheDir: dir, client: client);
      await svc2.load();
      expect(calls, isNot(contains('tagtree')));
      expect(calls, isNot(contains('materials')));

      // Local title search works.
      expect(svc.searchMaterials('书法'), hasLength(1));
      expect(svc.searchMaterials('不存在xyz'), isEmpty);
      await dir.delete(recursive: true);
    });
  });
}

class _FakeClient extends SmarteduClient {
  _FakeClient(this.tagTreeJson, this.materialJson, this.calls);

  final Map<String, dynamic> tagTreeJson;
  final Map<String, dynamic> materialJson;
  final List<String> calls;

  @override
  Future<int> getMaterialsVersion() async {
    calls.add('version');
    return 680630815;
  }

  @override
  Future<dynamic> getFileJson(String path, {Map<String, String>? query}) async {
    if (path.contains('national_lesson_tag')) {
      calls.add('tagtree');
      return tagTreeJson;
    }
    if (path.contains('teachingmaterials/part_100')) {
      calls.add('materials');
      return [materialJson];
    }
    if (path.contains('teachingmaterials/part_')) {
      return const <dynamic>[];
    }
    throw SmarteduApiException('unexpected path $path');
  }
}
