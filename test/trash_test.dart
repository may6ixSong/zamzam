import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zamzam/core/media_engine.dart';
import 'package:zamzam/ui/export_flow.dart';

void main() {
  test('을/를', () {
    expect(objectParticle('원본 영상'), '원본 영상을');
    expect(objectParticle('합친 조각 3개'), '합친 조각 3개를');
  });

  testWidgets('저장 후 "휴지통으로"를 누르면 원본 주소로 휴지통 요청을 하고 결과를 보여 준다', (tester) async {
    const channel = MethodChannel('zamzam/media');
    List<Object?>? asked;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'trash') {
        asked = call.arguments['uris'] as List<Object?>;
        return {'moved': true, 'count': 2, 'skipped': 0};
      }
      if (call.method == 'saveLocation') return 'Movies/ZamZam';
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => runExport(
                context,
                title: '합치는 중',
                job: () async =>
                    const ExportResult(uri: 'content://out', name: 'out.mp4', sizeBytes: 10, durationUs: 1000000),
                trashUris: const ['content://media/picker/0/x/media/1', 'content://media/external/video/media/2'],
                trashLabel: '합친 조각 2개',
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('저장했어요'), findsOneWidget);
    await tester.tap(find.text('합친 조각 2개를 휴지통으로'));
    await tester.pumpAndSettle();
    expect(asked, ['content://media/picker/0/x/media/1', 'content://media/external/video/media/2']);
    expect(find.text('합친 조각 2개를 휴지통으로 옮겼어요'), findsOneWidget);
  });
}
