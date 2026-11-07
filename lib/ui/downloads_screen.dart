import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/downloads.dart';
import '../core/media_engine.dart';
import '../core/time_format.dart';
import '../core/web_address.dart';
import 'merge_screen.dart';
import 'theme.dart';
import 'trim_screen.dart';

/// 동영상 다운로드 목록. 받은 영상을 바로 자르거나 합칠 수 있다.
///
/// [pickMode]면 합치기 화면에서 영상을 고르는 용도로, 고른 주소 목록을 돌려준다.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key, this.pickMode = false});

  final bool pickMode;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final _downloads = Downloads.instance;

  /// 고른 순서대로(합치기 순서가 된다).
  final List<String> _selected = [];
  late bool _selecting = widget.pickMode;

  @override
  void initState() {
    super.initState();
    _downloads.load();
  }

  void _toggle(DownloadItem item) {
    setState(() {
      if (!_selected.remove(item.id)) _selected.add(item.id);
    });
  }

  List<DownloadItem> get _selectedItems {
    final byId = {for (final e in _downloads.items) e.id: e};
    return [
      for (final id in _selected)
        if (byId[id] != null) byId[id]!,
    ];
  }

  void _trim(DownloadItem item) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => TrimScreen(initialUri: item.uri)));

  void _merge(List<DownloadItem> items) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MergeScreen(initialUris: [for (final e in items) e.uri])),
    );
    setState(() {
      _selected.clear();
      _selecting = false;
    });
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('다운로드 이력을 모두 지울까요?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: const Text('목록만 지워요. 갤러리에 저장된 동영상은 그대로 남아요.', style: TextStyle(height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(backgroundColor: Palette.bad, foregroundColor: Colors.white),
            child: const Text('모두 지우기'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _downloads.clearAll();
    setState(() => _selected.clear());
    _toast('다운로드 이력을 모두 지웠어요');
  }

  Future<void> _itemActions(DownloadItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Palette.s1,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.content_cut_rounded, color: Palette.accent),
              title: const Text('자르기'),
              onTap: () => Navigator.pop(c, 'trim'),
            ),
            ListTile(
              leading: const Icon(Icons.view_week_outlined, color: Palette.violet),
              title: const Text('합치기'),
              subtitle: const Text('이 영상부터 이어 붙일 영상을 골라요', style: TextStyle(fontSize: 12.5, color: Palette.muted)),
              onTap: () => Navigator.pop(c, 'merge'),
            ),
            ListTile(
              leading: const Icon(Icons.play_circle_outline_rounded),
              title: const Text('갤러리에서 보기'),
              onTap: () => Navigator.pop(c, 'open'),
            ),
            if (item.pageUrl.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: const Text('받은 페이지 주소 복사'),
                subtitle: Text(
                  displayUrl(item.pageUrl),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Palette.muted),
                ),
                onTap: () => Navigator.pop(c, 'copy'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: Palette.bad),
              title: const Text('목록에서 지우기'),
              subtitle: const Text('갤러리의 영상은 남아요', style: TextStyle(fontSize: 12.5, color: Palette.muted)),
              onTap: () => Navigator.pop(c, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'trim':
        _trim(item);
      case 'merge':
        setState(() {
          _selecting = true;
          _selected
            ..clear()
            ..add(item.id);
        });
        _toast('이어 붙일 영상을 순서대로 눌러 주세요');
      case 'open':
        MediaEngine.instance.openInGallery(item.uri).catchError((_) => _toast('열 수 있는 앱이 없어요'));
      case 'copy':
        Clipboard.setData(ClipboardData(text: item.pageUrl));
        _toast('주소를 복사했어요');
      case 'remove':
        await _downloads.remove(item);
        _selected.remove(item.id);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _downloads,
      builder: (context, _) {
        final items = _downloads.items;
        final tasks = _downloads.tasks;
        final chosen = _selectedItems;
        return PopScope(
          canPop: !_selecting || widget.pickMode,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              setState(() {
                _selecting = false;
                _selected.clear();
              });
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.pickMode ? '이어 붙일 영상 고르기' : (_selecting ? '${chosen.length}개 선택' : '동영상 다운로드')),
              actions: [
                if (!widget.pickMode && items.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() {
                      _selecting = !_selecting;
                      _selected.clear();
                    }),
                    child: Text(_selecting ? '취소' : '선택'),
                  ),
                if (!widget.pickMode && !_selecting)
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'clear') _clearAll();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'clear',
                        enabled: items.isNotEmpty || tasks.any((t) => t.state != TaskState.running),
                        child: const Row(
                          children: [
                            Icon(Icons.delete_sweep_outlined, color: Palette.bad),
                            SizedBox(width: 10),
                            Text('다운로드 이력 전부 지우기'),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            body: items.isEmpty && tasks.isEmpty
                ? const _Empty()
                : ListView(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 110),
                    children: [
                      for (final t in tasks) _TaskTile(task: t, downloads: _downloads),
                      if (tasks.isNotEmpty && items.isNotEmpty) const SizedBox(height: 8),
                      for (final item in items)
                        _ItemTile(
                          key: ValueKey(item.id),
                          item: item,
                          selecting: _selecting,
                          order: _selected.indexOf(item.id),
                          onTap: () => _selecting ? _toggle(item) : _itemActions(item),
                          onLongPress: () {
                            if (!_selecting) setState(() => _selecting = true);
                            _toggle(item);
                          },
                        ),
                    ],
                  ),
            bottomNavigationBar: _selecting
                ? SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                      child: widget.pickMode
                          ? FilledButton(
                              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                              onPressed: chosen.isEmpty
                                  ? null
                                  : () => Navigator.pop(context, [for (final e in chosen) e.uri]),
                              child: Text('${chosen.length}개 추가'),
                            )
                          : Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                                    onPressed: chosen.length == 1 ? () => _trim(chosen.first) : null,
                                    icon: const Icon(Icons.content_cut_rounded, size: 19),
                                    label: const Text('자르기'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  flex: 2,
                                  child: FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      minimumSize: const Size.fromHeight(50),
                                      backgroundColor: Palette.violet,
                                    ),
                                    onPressed: chosen.length >= 2 ? () => _merge(chosen) : null,
                                    icon: const Icon(Icons.view_week_outlined, size: 19),
                                    label: Text(chosen.length >= 2 ? '${chosen.length}개 합치기' : '2개 이상 골라 합치기'),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  )
                : null,
          ),
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.touch_app_outlined, size: 48, color: Palette.dim),
          SizedBox(height: 14),
          Text('받은 동영상이 없어요', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          SizedBox(height: 8),
          Text(
            '웹 페이지의 동영상을 손가락으로 꾸욱 누르면\n갤러리에 바로 저장되고 여기에 모여요.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Palette.muted, height: 1.6),
          ),
        ],
      ),
    ),
  );
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, required this.downloads});

  final DownloadTask task;
  final Downloads downloads;

  @override
  Widget build(BuildContext context) {
    final failed = task.state == TaskState.failed;
    final f = task.fraction;
    return Card(
      color: Palette.s1,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            Icon(
              failed ? Icons.error_outline_rounded : Icons.downloading_rounded,
              color: failed ? Palette.bad : Palette.accent,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  if (failed)
                    Text(
                      task.error ?? '실패했어요',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: Palette.bad),
                    )
                  else ...[
                    LinearProgressIndicator(
                      value: f,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                      backgroundColor: Palette.s3,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      task.total > 0
                          ? '${formatBytes(task.received)} / ${formatBytes(task.total)} · ${((f ?? 0) * 100).round()}%'
                          : '${formatBytes(task.received)} 받는 중',
                      style: const TextStyle(fontSize: 12, color: Palette.muted, fontFeatures: tabular),
                    ),
                  ],
                ],
              ),
            ),
            if (failed)
              IconButton(
                tooltip: '다시 시도',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () => downloads.retry(task),
              ),
            IconButton(
              tooltip: failed ? '지우기' : '취소',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => downloads.cancel(task),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemTile extends StatefulWidget {
  const _ItemTile({
    super.key,
    required this.item,
    required this.selecting,
    required this.order,
    required this.onTap,
    required this.onLongPress,
  });

  final DownloadItem item;
  final bool selecting;

  /// 고른 순서(0부터). 안 골랐으면 -1.
  final int order;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_ItemTile> createState() => _ItemTileState();
}

class _ItemTileState extends State<_ItemTile> {
  static final _thumbCache = <String, Uint8List?>{};
  Uint8List? _thumb;
  int? _durationUs;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    final uri = widget.item.uri;
    if (_thumbCache.containsKey(uri)) {
      _thumb = _thumbCache[uri];
    }
    try {
      final info = await MediaEngine.instance.probe(uri);
      if (!mounted) return;
      setState(() => _durationUs = info.durationUs);
      if (_thumb == null) {
        final t = await MediaEngine.instance.thumbnails(uri, count: 1, height: 160);
        _thumbCache[uri] = t.isEmpty ? null : t.first;
        if (mounted && t.isNotEmpty) setState(() => _thumb = t.first);
      }
    } catch (_) {
      if (mounted) setState(() => _missing = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final selected = widget.order >= 0;
    return Card(
      color: selected ? Palette.s3 : Palette.s1,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: selected ? const BorderSide(color: Palette.violet, width: 1.5) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: SizedBox(
                  width: 96,
                  height: 60,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _thumb != null
                          ? Image.memory(_thumb!, fit: BoxFit.cover, gaplessPlayback: true)
                          : ColoredBox(
                              color: Palette.s2,
                              child: Icon(
                                _missing ? Icons.broken_image_outlined : Icons.movie_outlined,
                                color: Palette.dim,
                              ),
                            ),
                      if (_durationUs != null)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .7),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              formatTime(_durationUs!, decimals: 0),
                              style: const TextStyle(fontSize: 10.5, color: Colors.white, fontFeatures: tabular),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.3),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _missing
                          ? '갤러리에서 지워졌어요'
                          : [
                              formatBytes(item.sizeBytes),
                              _date(item.time),
                              hostOf(item.pageUrl),
                            ].where((e) => e.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: _missing ? Palette.bad : Palette.muted),
                    ),
                  ],
                ),
              ),
              if (widget.selecting)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? Palette.violet : Colors.transparent,
                      border: Border.all(color: selected ? Palette.violet : Palette.dim, width: 2),
                    ),
                    child: selected
                        ? Text(
                            '${widget.order + 1}',
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Colors.white),
                          )
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _date(DateTime t) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  if (t.year == now.year && t.month == now.month && t.day == now.day) return '오늘 ${two(t.hour)}:${two(t.minute)}';
  return '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
}
