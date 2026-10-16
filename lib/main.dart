import 'package:flutter/material.dart';

import 'ui/menu_screen.dart';
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
      theme: buildTheme(),
      home: const MenuScreen(),
    );
  }
}
