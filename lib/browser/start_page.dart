import 'package:flutter/material.dart';

import '../core/browser_data.dart';
import '../core/web_address.dart';
import '../ui/theme.dart';
import 'video_sheet.dart';

const _defaults = [
  ('네이버', 'https://m.naver.com', Color(0xFF03C75A)),
  ('구글', 'https://www.google.com', Color(0xFF4285F4)),
  ('유튜브', 'https://m.youtube.com', Color(0xFFFF0033)),
  ('다음', 'https://m.daum.net', Color(0xFF3F7CFF)),
];

/// 새 탭 화면: 검색창, 바로가기, 북마크.
class StartPage extends StatelessWidget {
  const StartPage({super.key, required this.onOpen, required this.onSearchTap});

  final ValueChanged<String> onOpen;
  final VoidCallback onSearchTap;

  @override
  Widget build(BuildContext context) {
    final data = BrowserData.instance;
    return ColoredBox(
      color: Palette.bg,
      child: ListenableBuilder(
        listenable: data,
        builder: (context, _) {
          final marks = data.bookmarks.take(12).toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 36, 20, 24),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(11),
                      gradient: const LinearGradient(colors: [Palette.accent, Palette.violet]),
                    ),
                    child: const Icon(Icons.public_rounded, size: 21, color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  const Text('ZamZam', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 22),
              Material(
                color: Palette.s2,
                borderRadius: BorderRadius.circular(26),
                child: InkWell(
                  borderRadius: BorderRadius.circular(26),
                  onTap: onSearchTap,
                  child: SizedBox(
                    height: 52,
                    child: Row(
                      children: [
                        const SizedBox(width: 18),
                        const Icon(Icons.search_rounded, color: Palette.muted),
                        const SizedBox(width: 10),
                        Text('${data.engine.label} 검색 또는 주소 입력', style: const TextStyle(color: Palette.dim)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 26),
              Wrap(
                alignment: WrapAlignment.spaceAround,
                runSpacing: 18,
                children: [
                  for (final (name, url, color) in _defaults)
                    _Shortcut(label: name, letter: name.characters.first, color: color, onTap: () => onOpen(url)),
                ],
              ),
              const SizedBox(height: 26),
              Material(
                color: Palette.s1,
                borderRadius: BorderRadius.circular(16),
                child: ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  leading: const Icon(Icons.download_rounded, color: Palette.accent),
                  title: const Text('동영상 다운로드 목록', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text(
                    '동영상을 길게 눌러 받은 영상을 자르고 합쳐요',
                    style: TextStyle(fontSize: 12.5, color: Palette.muted),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: openDownloads,
                ),
              ),
              if (marks.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Text('북마크', style: TextStyle(fontSize: 13, color: Palette.muted)),
                const SizedBox(height: 6),
                for (final b in marks)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: Palette.s2,
                      child: Text(
                        hostOf(b.url).characters.firstOrNull?.toUpperCase() ?? '?',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                    title: Text(b.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      displayUrl(b.url),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Palette.muted),
                    ),
                    onTap: () => onOpen(b.url),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Shortcut extends StatelessWidget {
  const _Shortcut({required this.label, required this.letter, required this.color, required this.onTap});

  final String label;
  final String letter;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: onTap,
    child: SizedBox(
      width: 72,
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
            child: Text(
              letter,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
            ),
          ),
          const SizedBox(height: 7),
          Text(label, style: const TextStyle(fontSize: 12.5)),
        ],
      ),
    ),
  );
}
