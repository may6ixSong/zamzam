import 'dart:io';

import 'package:flutter/material.dart';

import 'browser/browser_screen.dart';
import 'core/native_player.dart';
import 'ui/app_keys.dart';
import 'ui/theme.dart';

void main() {
  startUp(android: Platform.isAndroid);
  runApp(const ZamZamApp());
}

/// 앱을 띄우기 전 준비. 플랫폼 채널을 쓰므로 반드시 바인딩을 먼저 준비한다
/// (순서가 틀리면 시작 화면에서 멈춘다). 부가 기능은 실패해도 앱 시작을 막지 않는다.
void startUp({required bool android}) {
  WidgetsFlutterBinding.ensureInitialized();
  if (android) {
    try {
      // 기본 재생기가 못 여는 영상은 안드로이드 기본 재생기로 미리보기한다.
      NativePlayerPlatform.install();
    } catch (e) {
      debugPrint('NativePlayerPlatform.install failed: $e');
    }
  }
}

class ZamZamApp extends StatelessWidget {
  const ZamZamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZamZam',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      theme: buildTheme(),
      home: const BrowserScreen(),
    );
  }
}
