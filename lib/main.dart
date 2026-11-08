import 'dart:io';

import 'package:flutter/material.dart';

import 'browser/browser_screen.dart';
import 'core/native_player.dart';
import 'ui/app_keys.dart';
import 'ui/theme.dart';

void main() {
  // 기본 재생기가 못 여는 영상은 안드로이드 기본 재생기로 미리보기한다.
  if (Platform.isAndroid) NativePlayerPlatform.install();
  runApp(const ZamZamApp());
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
