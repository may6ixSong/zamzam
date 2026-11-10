import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zamzam/core/downloads.dart';
import 'package:zamzam/core/json_store.dart';
import 'package:zamzam/ui/downloads_screen.dart';

void main() {
  testWidgets('작은 폰 화면에서도 영상 메뉴의 마지막 항목까지 닿는다', (tester) async {
    tester.view.physicalSize = const Size(720, 1280); // 360x640dp
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    Downloads.instance = Downloads(file: MemoryJsonFile(), deleteAppCopy: (_) async {});
    await Downloads.instance.load();
    Downloads.instance.add(
      DownloadItem(
        id: '1',
        uri: 'content://media/external/video/media/1',
        name: '테스트 영상.mp4',
        sizeBytes: 1000,
        sourceUrl: 'https://cdn.example.com/v.m3u8',
        pageUrl: 'https://example.com/page',
        time: DateTime(2026, 11, 8),
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('테스트 영상.mp4'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('목록에서 지우기'), 80, scrollable: find.byType(Scrollable).last);
    expect(find.text('목록에서 지우기').hitTestable(), findsOneWidget);
  });
}
