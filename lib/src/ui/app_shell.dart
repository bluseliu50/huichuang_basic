import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../store/app_state.dart';
import 'courses/courses_page.dart';
import 'player/player_page.dart';
import 'home/home_page.dart';
import 'pdf/textbooks_page.dart';
import 'search/search_page.dart';
import 'settings/settings_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.e2eResId});

  /// Debug/E2E hook: auto-open this lesson when set.
  final String? e2eResId;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _destinations = [
    (Icons.home_outlined, Icons.home, '首页'),
    (Icons.play_circle_outline, Icons.play_circle, '课程教学'),
    (Icons.book_outlined, Icons.book, '教材'),
    (Icons.search, Icons.search, '搜索'),
    (Icons.settings_outlined, Icons.settings, '设置'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppController>();
      app.bootstrap();
      final resid = widget.e2eResId;
      if (resid != null) {
        app.catalogLoadComplete.then((_) {
          if (!mounted) return;
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PlayerPage(resId: resid, title: 'E2E'),
            ),
          );
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 1000;
    final extended = width >= 1280;

    final pages = [
      const HomePage(),
      const CoursesPage(),
      const TextbooksPage(),
      const SearchPage(),
      const SettingsPage(),
    ];
    final body = IndexedStack(index: _index, children: pages);

    if (!wide) {
      return Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            for (final d in _destinations)
              NavigationDestination(
                icon: Icon(d.$1),
                selectedIcon: Icon(d.$2),
                label: d.$3,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            extended: extended,
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(
                  icon: Icon(d.$1),
                  selectedIcon: Icon(d.$2),
                  label: Text(d.$3),
                ),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}
