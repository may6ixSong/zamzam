import 'package:flutter/material.dart';

/// 화면이 바뀌어도 알림(스낵바)과 이동을 할 수 있게 앱 전체에서 쓰는 키.
final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

void showToast(String text, {SnackBarAction? action}) {
  final m = messengerKey.currentState;
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), action: action));
}
