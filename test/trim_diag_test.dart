import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zamzam/core/diag_log.dart';
import 'package:zamzam/ui/trim_screen.dart';

void main() {
  testWidgets('영상이 안 열리면 이유와 함께 "문제 진단"을 띄우고, 위쪽 버튼으로도 진단할 수 있다', (tester) async {
    const channel = MethodChannel('zamzam/media');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'probe':
          throw PlatformException(code: 'FAILED', message: '테스트 실패');
        case 'repair':
          throw PlatformException(code: 'FAILED', message: '고칠 수 없음');
        case 'diagnose':
          return '진단 내용';
      }
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: TrimScreen(initialUri: 'content://media/1')));
    await tester.pumpAndSettle();
    expect(find.text('영상을 열지 못했어요'), findsOneWidget);
    expect(find.textContaining('고칠 수 없음'), findsOneWidget);
    expect(calls, containsAllInOrder(['probe', 'repair']));
    expect(DiagLog.lines.any((l) => l.contains('정보 읽기 실패')), isTrue);
    expect(DiagLog.lines.any((l) => l.contains('사본 만들기 실패')), isTrue);
    // 창을 닫아도 위쪽 진단 버튼이 남아 있다.
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('문제 진단'), findsOneWidget);
  });
}
