import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:zamzam/core/diag_log.dart';
import 'package:zamzam/core/native_player.dart';
import 'package:zamzam/ui/trim_screen.dart';
import 'package:zamzam/ui/video_view.dart';

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
    expect(find.text('문제 진단'), findsOneWidget);
  });

  testWidgets('미리보기 재생기가 안 열려도 자르기 화면은 열린다(정지 화면으로 편집)', (tester) async {
    const channel = MethodChannel('zamzam/media');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'probe':
          return {
            'uri': 'content://media/2',
            'name': 'v.mp4',
            'size': 1000000,
            'durationUs': 20000000,
            'width': 1280,
            'height': 720,
            'videoMime': 'video/avc',
            'fps': 30.0,
            'keyframesUs': [for (var i = 0; i < 10; i++) i * 2000000],
            'keyframeBytes': [for (var i = 0; i < 10; i++) i * 100000],
            'videoBytes': 1000000,
          };
        case 'thumbnails':
          return <Object>[];
      }
      return null;
    });
    // 테스트 환경에는 재생기(플랫폼)가 없어 초기화가 실패한다 = 재생기가 안 열리는 상황.
    await tester.pumpWidget(const MaterialApp(home: TrimScreen(initialUri: 'content://media/2')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('미리보기를 준비하는 중'), findsNothing);
    expect(find.textContaining('미리보기 재생이 안 돼요'), findsOneWidget);
    expect(DiagLog.lines.any((l) => l.contains('재생 없이 편집')), isTrue);
  });

  testWidgets('미리보기 재생기가 응답 없이 멈춰도 10초 뒤 자르기 화면이 열린다', (tester) async {
    final saved = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = _HangingPlayer();
    addTearDown(() => VideoPlayerPlatform.instance = saved);
    const channel = MethodChannel('zamzam/media');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'probe':
          return {
            'uri': 'content://media/3',
            'durationUs': 20000000,
            'width': 1280,
            'height': 720,
            'videoMime': 'video/avc',
            'keyframesUs': [for (var i = 0; i < 10; i++) i * 2000000],
          };
        case 'thumbnails':
          return <Object>[];
      }
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: TrimScreen(initialUri: 'content://media/3')));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('미리보기를 준비하는 중'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('미리보기를 준비하는 중'), findsNothing);
    expect(find.textContaining('미리보기 재생이 안 돼요'), findsOneWidget);
    expect(DiagLog.lines.any((l) => l.contains('재생기 응답 없음')), isTrue);
  });
  testWidgets('기본 재생기가 멈추면 안드로이드 기본 재생기로 미리보기를 연다', (tester) async {
    final saved = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = NativePlayerPlatform(_HangingPlayer());
    nativePreviewEnabled = true;
    addTearDown(() {
      VideoPlayerPlatform.instance = saved;
      nativePreviewEnabled = false;
    });
    const media = MethodChannel('zamzam/media');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(media, (call) async {
      switch (call.method) {
        case 'probe':
          return {
            'uri': 'content://media/4',
            'durationUs': 20000000,
            'width': 854,
            'height': 480,
            'rotation': 90,
            'videoMime': 'video/avc',
            'keyframesUs': [for (var i = 0; i < 10; i++) i * 2000000],
          };
        case 'thumbnails':
          return <Object>[];
      }
      return null;
    });
    const player = MethodChannel('zamzam/player');
    final created = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(player, (call) async {
      if (call.method == 'create') {
        created.add(call.arguments['uri'] as String);
        // 기본 재생기가 준비되면 보내는 이벤트를 흉내 낸다.
        scheduleMicrotask(() {
          tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'zamzam/player',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('event', {
                'id': 1,
                'type': 'initialized',
                'durationMs': 20000,
                'width': 480,
                'height': 854,
                'rotation': 90,
              }),
            ),
            (_) {},
          );
        });
        return {'id': 1, 'textureId': 7};
      }
      if (call.method == 'position') return 0;
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: TrimScreen(initialUri: 'content://media/4')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(created, ['content://media/4']);
    expect(find.textContaining('미리보기를 준비하는 중'), findsNothing);
    expect(find.textContaining('미리보기 재생이 안 돼요'), findsNothing);
    expect(find.byType(Texture), findsOneWidget);
    expect(find.byType(RotatedBox), findsWidgets);
    expect(DiagLog.lines.any((l) => l.contains('안드로이드 재생기 준비 성공')), isTrue);
  });
}

/// 만들기·초기화·정리가 끝나지 않는 재생기(폰에서 '미리보기를 준비하는 중'에 멈추는 상황).
class _HangingPlayer extends VideoPlayerPlatform {
  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) => Completer<int?>().future;

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) => Completer<int?>().future;

  @override
  Future<void> dispose(int playerId) => Completer<void>().future;
}
