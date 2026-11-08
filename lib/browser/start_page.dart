import 'package:flutter/material.dart';

import '../core/browser_data.dart';
import '../core/web_address.dart';
import '../ui/theme.dart';
import 'favorites.dart';
import 'video_sheet.dart';

/// 새 탭 화면: 검색창, 즐겨찾기 바로가기, 다운로드 목록.
class StartPage extends StatelessWidget {
  const StartPage({
    super.key,
    required this.onOpen,
    required this.onSearchTap,
    required this.onOpenInNewTab,
    required this.onOpenAll,
    required this.onManage,
  });

  /// 이 탭에서 연다.
  final ValueChanged<String> onOpen;
  final VoidCallback onSearchTap;
  final ValueChanged<String> onOpenInNewTab;

  /// 즐겨찾기를 모두 새 탭으로 연다.
  final ValueChanged<List<String>> onOpenAll;
  final VoidCallback onManage;

  Future<void> _tileMenu(BuildContext context, PageEntry e) async {
    final data = BrowserData.instance;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Palette.s1,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: FavoriteIcon(entry: e, size: 32),
              title: Text(e.label, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(displayUrl(e.url), style: const TextStyle(fontSize: 12, color: Palette.muted)),
            ),
            const Divider(height: 8),
            ListTile(
              leading: const Icon(Icons.add_box_outlined),
              title: const Text('새 탭에서 열기'),
              onTap: () => Navigator.pop(c, 'newTab'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('수정'),
              onTap: () => Navigator.pop(c, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: Palette.bad),
              title: const Text('삭제'),
              onTap: () => Navigator.pop(c, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'newTab':
        onOpenInNewTab(e.url);
      case 'edit':
        final r = await showFavoriteEditor(context, initial: e);
        if (r != null) data.updateBookmark(e.url, r.$1, r.$2);
      case 'delete':
        data.removeBookmark(e.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = BrowserData.instance;
    return ColoredBox(
      color: Palette.bg,
      child: ListenableBuilder(
        listenable: data,
        builder: (context, _) {
          final favs = data.bookmarks;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 32, 16, 24),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const AppLogo(size: 38),
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
              const SizedBox(height: 22),
              Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Text('즐겨찾기', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                  const Spacer(),
                  if (favs.length > 1)
                    TextButton.icon(
                      onPressed: () => onOpenAll([for (final f in favs) f.url]),
                      icon: const Icon(Icons.open_in_new_rounded, size: 17),
                      label: Text('모두 열기 ${favs.length}'),
                    ),
                  TextButton(onPressed: onManage, child: const Text('편집')),
                ],
              ),
              const SizedBox(height: 4),
              LayoutBuilder(
                builder: (context, c) {
                  final perRow = (c.maxWidth / 84).floor().clamp(4, 8);
                  final w = c.maxWidth / perRow;
                  return Wrap(
                    runSpacing: 14,
                    children: [
                      for (final f in favs)
                        _Shortcut(
                          width: w,
                          icon: FavoriteIcon(entry: f),
                          label: f.label,
                          onTap: () => onOpen(f.url),
                          onLongPress: () => _tileMenu(context, f),
                        ),
                      _Shortcut(
                        width: w,
                        icon: Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: Palette.s2,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Palette.line),
                          ),
                          child: const Icon(Icons.add_rounded, color: Palette.muted, size: 26),
                        ),
                        label: '추가',
                        onTap: () async {
                          final r = await showFavoriteEditor(context);
                          if (r != null) data.addBookmark(r.$1, r.$2);
                        },
                      ),
                    ],
                  );
                },
              ),
              if (favs.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
                  child: Text('길게 누르면 새 탭에서 열기·수정·삭제', style: TextStyle(fontSize: 12, color: Palette.dim)),
                ),
              const SizedBox(height: 24),
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
            ],
          );
        },
      ),
    );
  }
}

class _Shortcut extends StatelessWidget {
  const _Shortcut({
    required this.width,
    required this.icon,
    required this.label,
    required this.onTap,
    this.onLongPress,
  });

  final double width;
  final Widget icon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            icon,
            const SizedBox(height: 7),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 앱 아이콘과 같은 모양: 어두운 바탕에 그라데이션 ▶ 와 저장 막대.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 38});

  final double size;

  static const _glow = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF5EE7FF), Color(0xFF7B6BFF), Color(0xFFFF5FA8)],
  );

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * .28),
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF262A39), Color(0xFF0B0C11)],
      ),
      border: Border.all(color: Palette.line, width: .5),
    ),
    child: ShaderMask(
      shaderCallback: _glow.createShader,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.play_arrow_rounded, size: size * .62, color: Colors.white),
          Container(
            width: size * .4,
            height: size * .08,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(size)),
          ),
        ],
      ),
    ),
  );
}
