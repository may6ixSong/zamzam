import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zamzam/ui/export_flow.dart';
import 'package:zamzam/ui/trash_flow.dart';

void main() {
  test('을/를', () {
    expect(objectParticle('원본 영상'), '원본 영상을');
    expect(objectParticle('조각 영상 3개'), '조각 영상 3개를');
  });

  Future<List<Object?>?> run(WidgetTester tester, {required bool confirm}) async {
    const channel = MethodChannel('zamzam/media');
    List<Object?>? asked;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'trash') {
        asked = call.arguments['uris'] as List<Object?>;
        return {'moved': true, 'count': 2, 'skipped': 0};
      }
      return null;
    });
    bool? moved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => moved = await confirmAndTrash(
                context,
                uris: const ['content://media/picker/0/x/media/1', 'content://media/external/video/media/2'],
                what: '조각 영상 2개',
                keeps: '합친 영상은 그대로 남아요.',
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('조각 영상 2개를 휴지통으로 옮길까요?'), findsOneWidget);
    await tester.tap(find.text(confirm ? '휴지통으로' : '취소'));
    await tester.pumpAndSettle();
    expect(moved, confirm);
    return asked;
  }

  testWidgets('확인하면 그 영상들만 휴지통으로 옮긴다', (tester) async {
    final asked = await run(tester, confirm: true);
    expect(asked, ['content://media/picker/0/x/media/1', 'content://media/external/video/media/2']);
    expect(find.text('조각 영상 2개를 휴지통으로 옮겼어요'), findsOneWidget);
  });

  testWidgets('취소하면 아무것도 옮기지 않는다', (tester) async {
    expect(await run(tester, confirm: false), isNull);
  });
}
