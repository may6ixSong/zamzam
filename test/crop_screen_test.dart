import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zamzam/ui/crop_screen.dart';

void main() {
  testWidgets('비율 1:1 을 고르고 돌린 뒤 저장하면 그 영역·회전으로 변환을 요청한다', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    Map<Object?, Object?>? asked;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('zamzam/media'), (call) async {
      switch (call.method) {
        case 'probe':
          return {
            'uri': 'content://media/external/video/media/7',
            'name': 'clip.mp4',
            'size': 40000000,
            'durationUs': 30000000,
            'width': 1920,
            'height': 1080,
            'videoMime': 'video/avc',
            'fps': 30.0,
            'keyframesUs': [for (var i = 0; i < 15; i++) i * 2000000],
            'videoBytes': 38000000,
            'audioBytes': 2000000,
          };
        case 'crop':
          asked = call.arguments as Map<Object?, Object?>;
          return {'uri': 'content://out', 'name': 'clip_crop.mp4', 'size': 10, 'durationUs': 30000000};
      }
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: CropScreen(initialUri: 'content://media/external/video/media/7')));
    await tester.pumpAndSettle();
    // 아무것도 안 바꾸면 저장할 수 없다.
    expect(find.text('영역을 정하거나 돌려 주세요'), findsOneWidget);
    expect(find.text('1920×1080'), findsNWidgets(2)); // 파일 정보 + 결과 크기

    await tester.tap(find.text('1:1'));
    await tester.pumpAndSettle();
    expect(find.text('1080×1080'), findsOneWidget);

    await tester.tap(find.text('회전'));
    await tester.pumpAndSettle();
    // 세로가 된 화면(1080×1920)에서 1:1 은 1080×1080.
    expect(find.text('90°'), findsOneWidget);
    expect(find.text('1080×1080'), findsOneWidget);

    await tester.tap(find.text('새 동영상 만들기'));
    await tester.pumpAndSettle();
    expect(asked!['rotateCcw'], 90);
    final crop = (asked!['crop'] as List).cast<double>();
    expect(crop[0], 0);
    expect(crop[2], 1);
    expect(crop[3] - crop[1], closeTo(1080 / 1920, 1e-9));
    expect(asked!['name'], 'clip');
    expect(find.text('저장했어요'), findsOneWidget);
  });
}
