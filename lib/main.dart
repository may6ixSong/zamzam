import 'package:flutter/material.dart';

import 'browser/browser_screen.dart';
import 'ui/app_keys.dart';
import 'ui/theme.dart';

void main() {
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
