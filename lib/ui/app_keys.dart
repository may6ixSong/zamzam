import 'package:flutter/material.dart';

/// 화면이 바뀌어도 알림(스낵바)과 이동을 할 수 있게 앱 전체에서 쓰는 키.
final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// 알림을 띄운다. 버튼이 있어도 [duration]이 지나면 닫힌다
/// (Flutter 는 버튼이 있는 알림을 기본으로 계속 띄워 둔다).
void showToast(String text, {SnackBarAction? action, Duration duration = const Duration(seconds: 3)}) {
  final m = messengerKey.currentState;
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), action: action, duration: duration, persist: false));
}
