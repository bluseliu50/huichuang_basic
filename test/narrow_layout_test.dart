// Narrow-width (mobile-class) layout behavior:
//  - 课程教学: leaf chapters must expose their lessons inline — exactly one
//    lesson opens the player directly, several expand inline. Before the
//    fix, tapping a leaf chapter in the narrow layout did NOTHING (the
//    lesson pane is wide-only).
//  - 教材: the filter levels and the book grid must share ONE scroll view;
//    the old fixed-height horizontal picker rows starved the grid on short
//    viewports.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huichuang_basic/src/api/client.dart';
import 'package:huichuang_basic/src/api/models.dart';
import 'package:huichuang_basic/src/api/catalog.dart';
import 'package:huichuang_basic/src/store/app_state.dart';
import 'package:huichuang_basic/src/ui/courses/courses_page.dart';
import 'package:huichuang_basic/src/ui/pdf/textbooks_page.dart';
import 'package:huichuang_basic/src/ui/player/player_page.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _tag(String id, String name, String dim,
        {List<Map<String, dynamic>> children = const []}) =>
    {
      'tag_id': id,
      'tag_name': name,
      'tag_dimension_id': dim,
      'hierarchies': [
        {'children': children}
      ],
    };

final _courseTagTree = {
  'hierarchies': [
    {
      'children': [
        _tag('s1', '小学', 'zxxxd', children: [
          _tag('g1', '一年级', 'zxxnj', children: [
            _tag('k1', '语文', 'zxxxk'),
          ]),
        ]),
      ]
    }
  ],
};

final _courseMaterial = TeachingMaterial.fromJson({
  'id': 'tm1',
  'title': '一年级语文上册',
  'tag_list': [
    {'tag_dimension_id': 'zxxxd', 'tag_name': '小学', 'tag_id': 's1'},
    {'tag_dimension_id': 'zxxnj', 'tag_name': '一年级', 'tag_id': 'g1'},
    {'tag_dimension_id': 'zxxxk', 'tag_name': '语文', 'tag_id': 'k1'},
    {'tag_dimension_id': 'zxxbb', 'tag_name': '统编版', 'tag_id': 'b1'},
    {'tag_dimension_id': 'zxxcc', 'tag_name': '上册', 'tag_id': 'c1'},
  ],
});

final _chapters = [
  ChapterNode(id: 'ch0', title: '第一单元', children: [
    const ChapterNode(id: 'ch1', title: '第一节 春晓'),
    const ChapterNode(id: 'ch2', title: '第二节 静夜思'),
    const ChapterNode(id: 'ch3', title: '第三节 空节'),
  ]),
];

Lesson _lesson(String id, String title, String leaf) => Lesson(
      id: id,
      title: title,
      tags: const {'bklx': '课程包'},
      chapterIds: ['ch0', leaf],
      isCoursePackage: true,
    );

final _lessons = [
  _lesson('l1', '春晓第一课', 'ch1'),
  _lesson('l2', '春晓第二课', 'ch1'),
  _lesson('l3', '静夜思整课', 'ch2'),
];

class _FakeClient extends SmarteduClient {
  _FakeClient() : super(dio: Dio());

  @override
  Future<int> getMaterialsVersion() async => 1;

  @override
  Future<dynamic> getFileJson(String path, {Map<String, String>? query}) async {
    if (path.contains('national_lesson_tag')) return _courseTagTree;
    if (path.contains('tch_material/version')) return {'module_version': 1};
    if (path.contains('tch_material_tag')) return _tbTagTree;
    if (path.contains('tch_material/part_')) return _tbBooks(path);
    throw SmarteduApiException('not found: $path', statusCode: 404);
  }

  @override
  Future<List<TeachingMaterial>> getMaterials() async => [_courseMaterial];

  @override
  Future<List<ChapterNode>> getChapterTree(String tmId) async => _chapters;

  @override
  Future<List<Lesson>> getLessons(String tmId) async => _lessons;

  @override
  Future<ResourceDetail> getTextbookDetail(String contentId) async =>
      throw const SmarteduApiException('no detail');
}

final _tbTagTree = {
  'hierarchies': [
    {
      'children': [
        _tag('troot', '电子教材', 'tb_root', children: [
          _tag('tb_s1', '小学', 'zxxxd', children: [
            _tag('tb_k1', '语文', 'zxxxk', children: [
              _tag('tb_b1', '统编版', 'zxxbb', children: [
                _tag('tb_g1', '一年级', 'zxxnj'),
                _tag('tb_g2', '二年级', 'zxxnj'),
              ]),
            ]),
          ]),
        ]),
      ]
    }
  ],
};

dynamic _tbBooks(String path) => [
      for (var i = 1; i <= 12; i++)
        {
          'id': 'tb_$i',
          'title': '测试教材 ${i.toString().padLeft(2, '0')}',
          'tag_list': [
            {'tag_dimension_id': 'zxxxd', 'tag_name': '小学', 'tag_id': 'tb_s1'},
            {'tag_dimension_id': 'zxxxk', 'tag_name': '语文', 'tag_id': 'tb_k1'},
            {'tag_dimension_id': 'zxxbb', 'tag_name': '统编版', 'tag_id': 'tb_b1'},
            {
              'tag_dimension_id': 'zxxnj',
              'tag_name': '一年级',
              'tag_id': 'tb_g1',
            },
          ],
        },
    ];

class _PushRecorder extends NavigatorObserver {
  final List<Route<Object?>> pushed = [];

  @override
  void didPush(Route<Object?> route, Route<Object?>? previousRoute) {
    pushed.add(route);
  }
}

Widget _host(AppController app, Widget page, {NavigatorObserver? observer}) =>
    ChangeNotifierProvider<AppController>.value(
      value: app,
      child: MaterialApp(
        navigatorObservers: [?observer],
        home: page,
      ),
    );

void _narrow(WidgetTester tester, {Size size = const Size(500, 900)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Builds an AppController whose catalog is already loaded. The disk
/// cache inside CatalogService does real dart:io — testWidgets' FakeAsync
/// never completes those futures, so bootstrap runs under runAsync.
Future<AppController> _app(WidgetTester tester,
    {Future<void> Function(AppController app)? after}) async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp
      .createTempSync('hc_narrow_${DateTime.now().millisecondsSinceEpoch}');
  final client = _FakeClient();
  final app = AppController(
    catalog: CatalogService(cacheDir: tmp, client: client),
    client: client,
  );
  await tester.runAsync(() async {
    await app.bootstrap();
    if (after != null) await after(app);
  });
  return app;
}

void main() {
  testWidgets('narrow courses: leaf chapter with several lessons expands inline',
      (tester) async {
    _narrow(tester);
    final app = await _app(tester,
        after: (app) => app.openMaterial(_courseMaterial));
    await tester.pumpWidget(_host(app, const CoursesPage()));
    await tester.pumpAndSettle();

    // Root chapter is expanded by default; the leaf tiles are visible.
    expect(find.text('第一节 春晓'), findsOneWidget);

    // Tapping a multi-lesson leaf must reveal its lessons inline —
    // before the fix the tap only flipped a highlight nobody could see.
    await tester.tap(find.text('第一节 春晓'));
    await tester.pumpAndSettle();
    expect(find.text('春晓第一课'), findsOneWidget);
    expect(find.text('春晓第二课'), findsOneWidget);
  });

  testWidgets('narrow courses: single-lesson chapter opens the player directly',
      (tester) async {
    _narrow(tester);
    final app = await _app(tester,
        after: (app) => app.openMaterial(_courseMaterial));
    final recorder = _PushRecorder();
    await tester.pumpWidget(
        _host(app, const CoursesPage(), observer: recorder));
    await tester.pumpAndSettle();

    // No pump after the tap: the pushed PlayerPage (media_kit) must not
    // build inside the test; inspect the route instead.
    await tester.tap(find.text('第二节 静夜思'));

    // [0] is the initial '/' route; [1] is the tap-triggered push.
    expect(recorder.pushed, hasLength(2));
    final route = recorder.pushed.last;
    expect(route, isA<MaterialPageRoute<void>>());
    final page = (route as MaterialPageRoute<void>)
        .builder(tester.element(find.byType(Navigator)));
    expect(page, isA<PlayerPage>());
    expect((page as PlayerPage).resId, 'l3');
  });

  testWidgets('textbooks: pickers and grid scroll as one view', (tester) async {
    _narrow(tester);
    // Pre-load the textbook catalog so the page's initState load finishes
    // without pending dart:io futures under FakeAsync.
    final app = await _app(tester, after: (app) => app.catalog.loadTextbooks());
    await tester.pumpWidget(_host(app, const TextbooksPage()));
    await tester.pumpAndSettle();

    // Exactly one scrollable (vertical); the old layout had four
    // fixed-height horizontal picker rows besides the grid.
    expect(find.byType(Scrollable), findsOneWidget);

    // Filter levels live inside that scroll view, not pinned above it.
    expect(
      find.descendant(
          of: find.byType(CustomScrollView), matching: find.text('学段')),
      findsOneWidget,
    );

    // Lazily-built grid: the last book is off-screen…
    expect(find.text('测试教材 12'), findsNothing);
    // …and the shared scroll view reaches it.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2500));
    await tester.pumpAndSettle();
    expect(find.text('测试教材 12'), findsOneWidget);
  });
}
