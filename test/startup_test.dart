import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:zamzam/core/native_player.dart';
import 'package:zamzam/main.dart';

void main() {
  // 바인딩이 준비되기 전(실제 앱의 main 과 같은 상황)에 시작 준비를 불러도 죽지 않아야 한다.
  // 예전에는 재생기 연결이 바인딩보다 먼저 돌아 앱이 시작 화면에서 멈췄다.
  test('바인딩 준비 전에 시작 준비를 불러도 앱이 시작된다', () {
    expect(() => startUp(android: true), returnsNormally);
    expect(VideoPlayerPlatform.instance, isA<NativePlayerPlatform>());
  });
}
