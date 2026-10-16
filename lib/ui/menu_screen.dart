import 'package:flutter/material.dart';

import '../core/media_engine.dart';
import 'merge_screen.dart';
import 'theme.dart';
import 'trim_screen.dart';

class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = isExpanded(c);
            final cut = _MenuCard(
              colors: const [Palette.accentDeep, Palette.accent, Color(0xFF7AA3FF)],
              icon: Icons.content_cut_rounded,
              title: '동영상 자르기',
              body: '영상 하나에서 시작·끝을 정해\n그 구간만 새 동영상으로 저장해요',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TrimScreen())),
            );
            final merge = _MenuCard(
              colors: const [Color(0xFF7C4DFF), Palette.violet, Color(0xFFB48CFF)],
              icon: Icons.view_week_outlined,
              title: '동영상 합치기',
              body: '여러 영상을 원하는 순서로\n이어 붙여 하나로 만들어요',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MergeScreen())),
            );
            final short = c.maxHeight < 560;
            final cards = wide || short
                ? Row(
                    children: [
                      Expanded(child: cut),
                      const SizedBox(width: 16),
                      Expanded(child: merge),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(child: cut),
                      const SizedBox(height: 14),
                      Expanded(child: merge),
                    ],
                  );
            final hPad = wide ? 28.0 : 16.0;
            return Padding(
              padding: EdgeInsets.fromLTRB(hPad, 8, hPad, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 54,
                    child: Row(
                      children: [
                        const _Logo(),
                        const SizedBox(width: 12),
                        const Text('ZamZam', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                        const Spacer(),
                        if (wide) const _SaveLocationChip(),
                      ],
                    ),
                  ),
                  if (!short) ...[
                    const SizedBox(height: 12),
                    Text(
                      wide ? '원본 화질 그대로, 용량은 딱 필요한 만큼' : '원본 화질 그대로,\n용량은 딱 필요한 만큼',
                      style: TextStyle(
                        fontSize: wide ? 30 : 25,
                        fontWeight: FontWeight.w800,
                        height: 1.3,
                        letterSpacing: -.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text('다시 인코딩하지 않고 자르고 이어 붙여요', style: TextStyle(fontSize: 13.5, color: Palette.muted)),
                  ],
                  SizedBox(height: short ? 8 : (wide ? 24 : 18)),
                  Expanded(child: cards),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) => Container(
    width: 34,
    height: 34,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(10),
      gradient: const LinearGradient(colors: [Palette.accent, Palette.violet]),
    ),
    child: const Icon(Icons.content_cut_rounded, size: 18, color: Colors.white),
  );
}

class _SaveLocationChip extends StatelessWidget {
  const _SaveLocationChip();

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: MediaEngine.instance.saveLocationLabel(),
    builder: (_, s) => Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(color: Palette.s2, borderRadius: BorderRadius.circular(17)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.folder_outlined, size: 16, color: Palette.muted),
          const SizedBox(width: 6),
          Text('저장 위치: ${s.data ?? ''}', style: const TextStyle(fontSize: 13, color: Palette.muted)),
        ],
      ),
    ),
  );
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.colors,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final List<Color> colors;
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  // 두 카드가 같은 크기가 되도록 받은 공간을 꽉 채운다.
  Widget build(BuildContext context) => SizedBox.expand(
    child: Material(
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: LayoutBuilder(
              builder: (context, c) => Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (c.maxHeight >= 200) ...[
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .18),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(icon, color: Colors.white, size: 26),
                        ),
                        const SizedBox(height: 14),
                      ],
                      Text(
                        title,
                        style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                      if (c.maxHeight >= 110) ...[
                        const SizedBox(height: 8),
                        Text(
                          body,
                          style: TextStyle(fontSize: 13.5, height: 1.5, color: Colors.white.withValues(alpha: .82)),
                        ),
                      ],
                    ],
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: .18), shape: BoxShape.circle),
                      child: const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
