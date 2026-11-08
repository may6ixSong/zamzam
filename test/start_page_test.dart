import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zamzam/browser/start_page.dart';
import 'package:zamzam/core/browser_data.dart';
import 'package:zamzam/core/json_store.dart';

void main() {
  testWidgets('즐겨찾기를 누르면 이동하고, 모두 열기는 전부 넘긴다', (tester) async {
    BrowserData.instance = BrowserData(file: MemoryJsonFile());
    await BrowserData.instance.load();
    final opened = <String>[];
    List<String>? all;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StartPage(
            onOpen: opened.add,
            onSearchTap: () {},
            onOpenInNewTab: (_) {},
            onOpenAll: (u) => all = u,
            onManage: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('네이버'), findsOneWidget);
    expect(find.text('추가'), findsOneWidget);
    await tester.tap(find.text('유튜브'));
    expect(opened, ['https://m.youtube.com']);
    await tester.tap(find.textContaining('모두 열기'));
    expect(all, ['https://m.naver.com', 'https://www.google.com', 'https://m.youtube.com', 'https://m.daum.net']);
  });
}
