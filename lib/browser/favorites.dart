import 'package:flutter/material.dart';

import '../core/browser_data.dart';
import '../core/web_address.dart';
import '../ui/theme.dart';

const _tileColors = [
  Color(0xFF03C75A),
  Color(0xFF4285F4),
  Color(0xFFFF4D4D),
  Color(0xFF3F7CFF),
  Color(0xFFFF9F1C),
  Color(0xFF9B6BFF),
  Color(0xFF00B8D9),
  Color(0xFFE94F9B),
];

/// 즐겨찾기 아이콘: 사이트 아이콘(favicon), 못 불러오면 첫 글자.
class FavoriteIcon extends StatelessWidget {
  const FavoriteIcon({super.key, required this.entry, this.size = 52});

  final PageEntry entry;
  final double size;

  @override
  Widget build(BuildContext context) {
    final host = hostOf(entry.url);
    final color = _tileColors[host.hashCode.abs() % _tileColors.length];
    final letter = Text(
      (entry.title.trim().isNotEmpty ? entry.title.trim() : host).characters.firstOrNull?.toUpperCase() ?? '?',
      style: TextStyle(fontSize: size * .38, fontWeight: FontWeight.w800, color: Colors.white),
    );
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * .3)),
      child: host.isEmpty
          ? letter
          : ClipRRect(
              borderRadius: BorderRadius.circular(size * .3),
              child: Image.network(
                'https://www.google.com/s2/favicons?domain=${Uri.encodeComponent(host)}&sz=128',
                width: size,
                height: size,
                fit: BoxFit.cover,
                // 아이콘이 없거나 기본 지구본(16px)만 오면 첫 글자로 보여 준다.
                frameBuilder: (context, child, frame, _) => frame == null ? Center(child: letter) : child,
                errorBuilder: (_, _, _) => Center(child: letter),
              ),
            ),
    );
  }
}

/// 즐겨찾기 추가·수정 창. 저장하면 (주소, 이름)을 돌려준다.
Future<(String, String)?> showFavoriteEditor(BuildContext context, {PageEntry? initial}) {
  final url = TextEditingController(text: initial?.url ?? '');
  final title = TextEditingController(text: initial?.title ?? '');
  return showDialog<(String, String)>(
    context: context,
    builder: (c) {
      void save() {
        final u = resolveInput(url.text, BrowserData.instance.engine);
        if (u.isEmpty) return;
        final t = title.text.trim().isEmpty ? displayUrl(u).split('/').first : title.text.trim();
        Navigator.pop(c, (u, t));
      }

      return AlertDialog(
        title: Text(initial == null ? '즐겨찾기 추가' : '즐겨찾기 수정'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              autofocus: initial == null,
              decoration: const InputDecoration(labelText: '이름', hintText: '비워 두면 주소로'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: url,
              autofocus: initial != null,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '주소', hintText: '예: naver.com'),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => save(),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
          FilledButton(onPressed: save, child: const Text('저장')),
        ],
      );
    },
  );
}

/// 즐겨찾기 관리: 끌어서 순서 바꾸기, 수정, 삭제, 추가. 누르면 그 주소를 돌려준다.
class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final data = BrowserData.instance;
    return ListenableBuilder(
      listenable: data,
      builder: (context, _) {
        final list = data.bookmarks;
        return Scaffold(
          appBar: AppBar(title: const Text('즐겨찾기')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () async {
              final r = await showFavoriteEditor(context);
              if (r != null) data.addBookmark(r.$1, r.$2);
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('추가'),
          ),
          body: list.isEmpty
              ? const Center(
                  child: Text(
                    '즐겨찾기가 없어요\n아래 ‘추가’나 메뉴의 ☆ 로 등록해요',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Palette.muted, height: 1.6),
                  ),
                )
              : Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 6),
                      child: Text(
                        '≡ 를 끌어 순서를 바꿔요. 이 순서대로 새 탭 화면에 보여요.',
                        style: TextStyle(fontSize: 12.5, color: Palette.muted),
                      ),
                    ),
                    Expanded(
                      child: ReorderableListView.builder(
                        padding: const EdgeInsets.only(bottom: 96),
                        buildDefaultDragHandles: false,
                        itemCount: list.length,
                        onReorderItem: data.moveBookmark,
                        itemBuilder: (context, i) {
                          final e = list[i];
                          return ListTile(
                            key: ValueKey(e.url),
                            leading: FavoriteIcon(entry: e, size: 36),
                            title: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              displayUrl(e.url),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: Palette.muted),
                            ),
                            onTap: () => Navigator.pop(context, e.url),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '수정',
                                  icon: const Icon(Icons.edit_outlined, size: 20),
                                  onPressed: () async {
                                    final r = await showFavoriteEditor(context, initial: e);
                                    if (r != null) data.updateBookmark(e.url, r.$1, r.$2);
                                  },
                                ),
                                IconButton(
                                  tooltip: '삭제',
                                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                                  onPressed: () => data.removeBookmark(e.url),
                                ),
                                ReorderableDragStartListener(
                                  index: i,
                                  child: const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Icon(Icons.drag_handle_rounded, color: Palette.dim),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}
