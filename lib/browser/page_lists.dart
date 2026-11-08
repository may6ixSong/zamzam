import 'package:flutter/material.dart';

import '../core/browser_data.dart';
import '../core/web_address.dart';
import '../ui/theme.dart';
import 'browser_tab.dart';

class TabsResult {
  const TabsResult.pick(int this.index) : newTab = false;
  const TabsResult.create() : index = null, newTab = true;

  final int? index;
  final bool newTab;
}

/// 열린 탭 목록.
class TabsScreen extends StatefulWidget {
  const TabsScreen({super.key, required this.tabs, required this.current, required this.onClose});

  final List<BrowserTab> tabs;
  final int current;
  final void Function(BrowserTab) onClose;

  @override
  State<TabsScreen> createState() => _TabsScreenState();
}

class _TabsScreenState extends State<TabsScreen> {
  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs;
    final current = widget.current < tabs.length ? tabs[widget.current] : null;
    return Scaffold(
      appBar: AppBar(title: Text('탭 ${tabs.length}개')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pop(context, const TabsResult.create()),
        icon: const Icon(Icons.add_rounded),
        label: const Text('새 탭'),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 96),
        itemCount: tabs.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final t = tabs[i];
          final selected = t == current;
          return Dismissible(
            key: ValueKey(t.id),
            onDismissed: (_) {
              widget.onClose(t);
              if (widget.tabs.length <= 1 && mounted) Navigator.pop(context, const TabsResult.pick(0));
              setState(() {});
            },
            child: Material(
              color: selected ? Palette.s3 : Palette.s1,
              borderRadius: BorderRadius.circular(14),
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: selected ? const BorderSide(color: Palette.accent, width: 1.5) : BorderSide.none,
                ),
                leading: const Icon(Icons.public_rounded, color: Palette.muted),
                title: Text(
                  t.isStartPage ? '새 탭' : (t.title.isEmpty ? displayUrl(t.url) : t.title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: t.isStartPage
                    ? null
                    : Text(
                        displayUrl(t.url),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Palette.muted),
                      ),
                trailing: IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    widget.onClose(t);
                    setState(() {});
                  },
                ),
                onTap: () => Navigator.pop(context, TabsResult.pick(widget.tabs.indexOf(t))),
              ),
            ),
          );
        },
      ),
    );
  }
}

enum PageListKind { bookmarks, history }

/// 즐겨찾기 또는 방문 기록. 누르면 그 주소를 돌려준다.
class PageListScreen extends StatelessWidget {
  const PageListScreen({super.key, required this.kind});

  final PageListKind kind;

  @override
  Widget build(BuildContext context) {
    final data = BrowserData.instance;
    final isHistory = kind == PageListKind.history;
    return ListenableBuilder(
      listenable: data,
      builder: (context, _) {
        final list = isHistory ? data.history : data.bookmarks;
        return Scaffold(
          appBar: AppBar(
            title: Text(isHistory ? '방문 기록' : '즐겨찾기'),
            actions: [
              if (isHistory && list.isNotEmpty)
                TextButton(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('방문 기록을 모두 지울까요?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
                          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('모두 지우기')),
                        ],
                      ),
                    );
                    if (ok == true) data.clearHistory();
                  },
                  child: const Text('모두 지우기'),
                ),
            ],
          ),
          body: list.isEmpty
              ? Center(
                  child: Text(
                    isHistory ? '방문 기록이 없어요' : '즐겨찾기가 없어요\n메뉴의 ☆ 버튼으로 추가해요',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Palette.muted, height: 1.6),
                  ),
                )
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final e = list[i];
                    final showDay = isHistory && (i == 0 || !_sameDay(list[i - 1].time, e.time));
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showDay)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                            child: Text(
                              _dayLabel(e.time),
                              style: const TextStyle(fontSize: 12.5, color: Palette.muted),
                            ),
                          ),
                        ListTile(
                          title: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            displayUrl(e.url),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: Palette.muted),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.close_rounded, size: 20),
                            onPressed: () => isHistory ? data.removeVisit(e.url) : data.removeBookmark(e.url),
                          ),
                          onTap: () => Navigator.pop(context, e.url),
                        ),
                      ],
                    );
                  },
                ),
        );
      },
    );
  }
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

String _dayLabel(DateTime t) {
  final now = DateTime.now();
  if (_sameDay(t, now)) return '오늘';
  if (_sameDay(t, now.subtract(const Duration(days: 1)))) return '어제';
  return '${t.year}. ${t.month}. ${t.day}.';
}
