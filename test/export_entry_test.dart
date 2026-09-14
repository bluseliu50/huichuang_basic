// Issue #5 entry points: every textbook card carries a 下载 button, the
// PDF reader opens download-first (cache) and exposes the export action
// only once the bytes are local. The download tap is exercised up to the
// detail fetch — the fake client throws, asserting the error snackbar
// path without touching FilePicker (native, unavailable in tests).
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huichuang_basic/src/api/catalog.dart';
import 'package:huichuang_basic/src/api/client.dart';
import 'package:huichuang_basic/src/api/models.dart';
import 'package:huichuang_basic/src/download/download.dart';
import 'package:huichuang_basic/src/stream/proxy.dart';
import 'package:huichuang_basic/src/store/app_state.dart';
import 'package:huichuang_basic/src/ui/pdf/pdf_reader_page.dart';
import 'package:huichuang_basic/src/ui/pdf/textbooks_page.dart';
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

final _tbTagTree = {
  'hierarchies': [
    {
      'children': [
        _tag('troot', '电子教材', 'tb_root', children: [
          _tag('tb_s1', '小学', 'zxxxd', children: [
            _tag('tb_k1', '语文', 'zxxxk', children: [
              _tag('tb_b1', '统编版', 'zxxbb', children: [
                _tag('tb_g1', '一年级', 'zxxnj'),
              ]),
            ]),
          ]),
        ]),
      ]
    }
  ]
};

dynamic _tbBooks(String path) {
  // Only part_100 carries a book; the other three parts serve empty lists
  // so the grid holds exactly one card.
  if (!path.contains('part_100')) return <Map<String, dynamic>>[];
  return [
    {
      'id': 'tb_1',
      'title': '测试教材',
      'tag_list': [
        {'tag_dimension_id': 'zxxxd', 'tag_name': '小学', 'tag_id': 'tb_s1'},
        {'tag_dimension_id': 'zxxxk', 'tag_name': '语文', 'tag_id': 'tb_k1'},
        {'tag_dimension_id': 'zxxbb', 'tag_name': '统编版', 'tag_id': 'tb_b1'},
        {'tag_dimension_id': 'zxxnj', 'tag_name': '一年级', 'tag_id': 'tb_g1'},
      ],
    },
  ];
}

class _FakeClient extends SmarteduClient {
  _FakeClient() : super(dio: Dio());

  @override
  Future<int> getMaterialsVersion() async => 1;

  @override
  Future<dynamic> getFileJson(String path, {Map<String, String>? query}) async {
    if (path.contains('national_lesson_tag')) {
      return {'hierarchies': []};
    }
    if (path.contains('tch_material/version')) return {'module_version': 1};
    if (path.contains('tch_material_tag')) return _tbTagTree;
    if (path.contains('tch_material/part_')) return _tbBooks(path);
    throw SmarteduApiException('not found: $path', statusCode: 404);
  }

  @override
  Future<List<ChapterNode>> getChapterTree(String tmId) async => [];

  @override
  Future<List<Lesson>> getLessons(String tmId) async => [];
}

Widget _host(AppController app, Widget page) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: app),
        Provider<StreamProxy>.value(value: StreamProxy()),
      ],
      child: MaterialApp(home: page),
    );

Future<AppController> _app(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync(
      'hc_export_entry_${DateTime.now().millisecondsSinceEpoch}');
  final client = _FakeClient();
  final app = AppController(
    catalog: CatalogService(cacheDir: tmp, client: client),
    client: client,
  );
  await tester.runAsync(() async {
    await app.bootstrap();
    await app.catalog.loadTextbooks();
  });
  return app;
}

/// Smallest pdfium-tolerable PDF (xref-less; pdfium rebuilds it).
const _tinyPdf = '%PDF-1.4\n'
    '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
    '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
    '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\n'
    'trailer<</Size 4/Root 1 0 R>>\n%%EOF';

void main() {
  testWidgets('textbook card shows a download button', (tester) async {
    final app = await _app(tester);
    await tester.pumpWidget(_host(app, const TextbooksPage()));
    await tester.pumpAndSettle();

    final badge = find.descendant(
      of: find.byType(Card),
      matching: find.byIcon(Icons.download_outlined),
    );
    expect(badge, findsOneWidget);
  });

  testWidgets('textbook download tap surfaces the failure snackbar',
      (tester) async {
    final app = await _app(tester);
    await tester.pumpWidget(_host(app, const TextbooksPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pump(); // begin the detail fetch → throw → snackbar
    await tester.pumpAndSettle();

    expect(find.textContaining('下载教材失败'), findsOneWidget);
  });

  testWidgets('reader with an uncached document surfaces the download error',
      (tester) async {
    // The binding's fake HttpClient answers 400, driving _prepare into the
    // error state; the export action must stay hidden without local bytes.
    await tester.pumpWidget(
      MaterialApp(
        home: PdfReaderPage(
          title: '测试教材',
          url: Uri.parse('http://127.0.0.1:1/file?u=hc_no_such_doc'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('打开失败'), findsOneWidget);
    expect(find.byTooltip('下载 PDF'), findsNothing);
  });

  testWidgets('reader with a cached document opens and offers export',
      (tester) async {
    final slot = cacheSlotFor(Uri.parse('hc_cached_doc'));
    slot.parent.createSync(recursive: true);
    slot.writeAsStringSync(_tinyPdf);
    addTearDown(() {
      try {
        slot.deleteSync();
      } catch (_) {}
    });

    await tester.pumpWidget(
      MaterialApp(
        home: PdfReaderPage(
          title: '测试教材',
          url: Uri.parse('http://127.0.0.1:1/file?u=hc_cached_doc'),
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('下载 PDF'), findsOneWidget);
  });
}
