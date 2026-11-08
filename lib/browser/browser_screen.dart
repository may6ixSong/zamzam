import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/browser_data.dart';
import '../core/downloads.dart';
import '../core/media_engine.dart';
import '../core/web_address.dart';
import '../ui/app_keys.dart';
import '../ui/menu_screen.dart';
import '../ui/theme.dart';
import 'browser_tab.dart';
import 'favorites.dart';
import 'page_lists.dart';
import 'start_page.dart';
import 'video_sheet.dart';

/// 앱의 첫 화면: 인터넷 브라우저.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> implements TabHost {
  final _data = BrowserData.instance;
  final _downloads = Downloads.instance;
  final _tabs = <BrowserTab>[];
  int _current = 0;

  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  bool _editing = false;

  /// 전체 화면 동영상(Android).
  Widget? _fullscreen;
  VoidCallback? _exitFullscreen;

  BrowserTab get _tab => _tabs[_current];

  @override
  void initState() {
    super.initState();
    _data.load();
    _downloads.load();
    _data.addListener(_rebuild);
    _downloads.addListener(_rebuild);
    _addressFocus.addListener(_onFocus);
    _address.addListener(_rebuild);
    _newTab();
  }

  @override
  void dispose() {
    _data.removeListener(_rebuild);
    _downloads.removeListener(_rebuild);
    for (final t in _tabs) {
      t.removeListener(_onTabChanged);
      t.dispose();
    }
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// 주소창 편집을 시작한다. 입력칸은 편집할 때만 만들어지고 autofocus 로 키보드를 띄운다.
  void _startEdit() {
    _address.text = _tab.isStartPage ? '' : _tab.url;
    _address.selection = TextSelection(baseOffset: 0, extentOffset: _address.text.length);
    setState(() => _editing = true);
  }

  void _endEdit() {
    _addressFocus.unfocus();
    if (_editing) setState(() => _editing = false);
  }

  void _onFocus() {
    if (!_addressFocus.hasFocus && _editing) setState(() => _editing = false);
  }

  void _onTabChanged() {
    if (!mounted) return;
    setState(() {});
  }

  // ------------------------------------------------------------------ tabs

  BrowserTab _newTab({String? url}) {
    final t = BrowserTab(host: this, data: _data, desktop: _data.desktopMode);
    t.addListener(_onTabChanged);
    setState(() {
      _tabs.add(t);
      _current = _tabs.length - 1;
    });
    if (url != null) t.load(url);
    return t;
  }

  void _closeTab(BrowserTab t) {
    final i = _tabs.indexOf(t);
    if (i < 0) return;
    t.removeListener(_onTabChanged);
    t.controller.loadRequest(Uri.parse('about:blank')).catchError((_) {});
    setState(() {
      _tabs.removeAt(i);
      if (_tabs.isEmpty) {
        _newTab();
      } else if (_current >= _tabs.length) {
        _current = _tabs.length - 1;
      } else if (i < _current) {
        _current--;
      }
    });
    t.dispose();
  }

  /// 즐겨찾기를 모두 새 탭으로 연다. 첫 번째는 지금 보고 있는 빈 탭을 쓴다.
  void _openAll(List<String> urls) {
    if (urls.isEmpty) return;
    final reuse = _tab.isStartPage && _tab.behindStart == null;
    final first = _current;
    for (var i = 0; i < urls.length; i++) {
      if (i == 0 && reuse) {
        _tab.load(urls[0]);
      } else {
        _newTab(url: urls[i]);
      }
    }
    // 첫 번째 사이트를 보여 준다.
    setState(() => _current = reuse ? first : _tabs.length - urls.length);
    showToast('즐겨찾기 ${urls.length}개를 탭으로 열었어요');
  }

  /// 주소창 ☆: 지금 페이지를 바로 즐겨찾기에 넣거나 뺀다.
  void _toggleFavorite() {
    final page = _tab.currentPage;
    if (page == null) return;
    if (_data.isBookmarked(page.url)) {
      _data.removeBookmark(page.url);
      showToast(
        '즐겨찾기에서 뺐어요',
        action: SnackBarAction(label: '되돌리기', onPressed: () => _data.addBookmark(page.url, page.title)),
      );
      return;
    }
    final name = page.title.trim().isEmpty ? displayUrl(page.url).split('/').first : page.title.trim();
    _data.addBookmark(page.url, name);
    showToast(
      '즐겨찾기에 추가했어요 · 새 탭 화면에 보여요',
      action: SnackBarAction(
        label: '이름 수정',
        onPressed: () async {
          final ctx = navigatorKey.currentContext;
          if (ctx == null) return;
          final current = _data.bookmarks.where((b) => b.url == page.url).firstOrNull;
          if (current == null) return;
          final r = await showFavoriteEditor(ctx, initial: current);
          if (r != null) _data.updateBookmark(page.url, r.$1, r.$2);
        },
      ),
    );
  }

  Future<void> _manageFavorites() async {
    final url = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => FavoritesScreen(current: _tab.currentPage)),
    );
    if (url != null && mounted) _tab.load(url);
  }

  Future<void> _showTabs() async {
    final picked = await Navigator.push<TabsResult>(
      context,
      MaterialPageRoute(
        builder: (_) => TabsScreen(tabs: _tabs, current: _current, onClose: _closeTab),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked.newTab) {
      _newTab();
      _startEdit();
    } else if (picked.index != null && picked.index! < _tabs.length) {
      setState(() => _current = picked.index!);
    }
  }

  // ------------------------------------------------------------------ navigation

  void _go(String input) {
    final url = resolveInput(input, _data.engine);
    _endEdit();
    if (url.isEmpty) return;
    _tab.load(url);
  }

  Future<void> _back() async {
    if (_fullscreen != null) {
      _exitFullscreen?.call();
      return;
    }
    if (_editing) {
      _endEdit();
      return;
    }
    final t = _tab;
    if (t.canLeaveStartPage || (!t.isStartPage && t.canGoBack)) {
      await t.goBack();
      return;
    }
    if (!t.isStartPage) {
      t.showStartPage();
      return;
    }
    if (_tabs.length > 1) {
      _closeTab(t);
      return;
    }
    SystemNavigator.pop();
  }

  // ------------------------------------------------------------------ TabHost

  @override
  void onVideoHit(BrowserTab tab, VideoHit hit) {
    if (tab != _tab || !mounted) return;
    showVideoSheet(context, tab, hit);
  }

  @override
  Future<bool> openExternal(String url) async {
    final ok = await MediaEngine.instance.openExternal(url).catchError((_) => false);
    if (!ok) showToast('이 주소를 열 수 있는 앱이 없어요');
    return ok;
  }

  @override
  Future<void> alert(String message) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      content: Text(message),
      actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('확인'))],
    ),
  );

  @override
  Future<bool> confirm(String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('확인')),
          ],
        ),
      ) ??
      false;

  @override
  Future<String?> prompt(String message, String defaultText) {
    final ctrl = TextEditingController(text: defaultText);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            TextField(controller: ctrl, autofocus: true),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('확인')),
        ],
      ),
    );
  }

  @override
  void showFullscreen(Widget widget, VoidCallback exit) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    setState(() {
      _fullscreen = widget;
      _exitFullscreen = exit;
    });
  }

  @override
  void hideFullscreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!mounted) return;
    setState(() {
      _fullscreen = null;
      _exitFullscreen = null;
    });
  }

  @override
  Future<List<String>> pickFiles(List<String> acceptTypes, bool multiple) =>
      MediaEngine.instance.pickFiles(acceptTypes, multiple: multiple).catchError((_) => <String>[]);

  // ------------------------------------------------------------------ menu

  Future<void> _openMenu() async {
    final t = _tab;
    final onPage = !t.isStartPage;
    final marked = onPage && _data.isBookmarked(t.url);
    final running = _downloads.runningCount;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Palette.s1,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Row(
                  children: [
                    _QuickButton(icon: Icons.add_box_outlined, label: '새 탭', onTap: () => Navigator.pop(c, 'newTab')),
                    _QuickButton(
                      icon: marked ? Icons.star_rounded : Icons.star_outline_rounded,
                      label: marked ? '즐겨찾기 해제' : '즐겨찾기',
                      enabled: onPage,
                      highlight: marked,
                      onTap: () => Navigator.pop(c, 'bookmark'),
                    ),
                    _QuickButton(
                      icon: Icons.share_outlined,
                      label: '공유',
                      enabled: onPage,
                      onTap: () => Navigator.pop(c, 'share'),
                    ),
                    _QuickButton(
                      icon: Icons.refresh_rounded,
                      label: '새로고침',
                      enabled: onPage,
                      onTap: () => Navigator.pop(c, 'reload'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 16),
              _MenuTile(
                icon: Icons.download_rounded,
                title: '동영상 다운로드 목록',
                subtitle: running > 0 ? '$running개 받는 중' : '받은 영상 자르기·합치기',
                color: Palette.accent,
                onTap: () => Navigator.pop(c, 'downloads'),
              ),
              _MenuTile(
                icon: Icons.manage_search_rounded,
                title: '이 페이지의 동영상 찾기',
                enabled: onPage,
                onTap: () => Navigator.pop(c, 'findVideos'),
              ),
              _MenuTile(
                icon: Icons.content_cut_rounded,
                title: '동영상 편집 (갤러리에서 고르기)',
                onTap: () => Navigator.pop(c, 'editor'),
              ),
              const Divider(height: 16),
              _MenuTile(icon: Icons.star_outline_rounded, title: '즐겨찾기 편집', onTap: () => Navigator.pop(c, 'bookmarks')),
              _MenuTile(icon: Icons.history_rounded, title: '방문 기록', onTap: () => Navigator.pop(c, 'history')),
              _MenuTile(
                icon: Icons.link_rounded,
                title: '페이지 주소 복사',
                enabled: onPage,
                onTap: () => Navigator.pop(c, 'copy'),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.desktop_windows_outlined),
                title: const Text('데스크톱 사이트'),
                value: _data.desktopMode,
                onChanged: (_) => Navigator.pop(c, 'desktop'),
              ),
              _MenuTile(
                icon: Icons.search_rounded,
                title: '검색 엔진',
                subtitle: _data.engine.label,
                onTap: () => Navigator.pop(c, 'engine'),
              ),
              _MenuTile(
                icon: Icons.cleaning_services_outlined,
                title: '인터넷 사용 기록 삭제',
                onTap: () => Navigator.pop(c, 'clear'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'newTab':
        _newTab();
        _startEdit();
      case 'bookmark':
        _toggleFavorite();
      case 'share':
        SharePlus.instance.share(ShareParams(uri: Uri.tryParse(t.url), subject: t.title));
      case 'reload':
        t.reload();
      case 'downloads':
        openDownloads();
      case 'findVideos':
        showPageVideos(context, t);
      case 'editor':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const MenuScreen()));
      case 'bookmarks':
        _manageFavorites();
      case 'history':
        final url = await Navigator.push<String>(
          context,
          MaterialPageRoute(builder: (_) => const PageListScreen(kind: PageListKind.history)),
        );
        if (url != null) _tab.load(url);
      case 'copy':
        Clipboard.setData(ClipboardData(text: t.url));
        showToast('주소를 복사했어요');
      case 'desktop':
        _data.desktopMode = !_data.desktopMode;
        for (final tab in _tabs) {
          tab.desktopMode = _data.desktopMode;
        }
      case 'engine':
        _pickEngine();
      case 'clear':
        _clearBrowsing();
    }
  }

  Future<void> _pickEngine() async {
    final e = await showDialog<SearchEngine>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('검색 엔진'),
        children: [
          for (final e in SearchEngine.values)
            ListTile(
              leading: Icon(
                e == _data.engine ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: e == _data.engine ? Palette.accent : Palette.dim,
              ),
              title: Text(e.label),
              onTap: () => Navigator.pop(c, e),
            ),
        ],
      ),
    );
    if (e != null) _data.engine = e;
  }

  Future<void> _clearBrowsing() async {
    var history = true, cookies = false, cache = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('인터넷 사용 기록 삭제'),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(value: history, onChanged: (v) => set(() => history = v!), title: const Text('방문 기록')),
              CheckboxListTile(value: cache, onChanged: (v) => set(() => cache = v!), title: const Text('캐시된 이미지·파일')),
              CheckboxListTile(
                value: cookies,
                onChanged: (v) => set(() => cookies = v!),
                title: const Text('쿠키·사이트 데이터'),
                subtitle: const Text('로그인이 풀려요', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('삭제')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (history) _data.clearHistory();
    if (cache) await _tab.controller.clearCache();
    if (cookies) {
      await WebViewCookieManager().clearCookies();
      for (final t in _tabs) {
        await t.controller.clearLocalStorage();
      }
    }
    showToast('삭제했어요');
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final t = _tab;
    final full = _fullscreen;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: full != null
            ? ColoredBox(
                color: Colors.black,
                child: SizedBox.expand(child: full),
              )
            : SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    _AddressBar(
                      tab: t,
                      controller: _address,
                      focus: _addressFocus,
                      editing: _editing,
                      bookmarked: !t.isStartPage && _data.isBookmarked(t.url),
                      onSubmit: _go,
                      onStartEdit: _startEdit,
                      onToggleFavorite: _toggleFavorite,
                      onCancel: _endEdit,
                    ),
                    SizedBox(
                      height: 2.5,
                      child: t.loading && !t.isStartPage
                          ? LinearProgressIndicator(
                              value: t.progress / 100,
                              backgroundColor: Colors.transparent,
                              minHeight: 2.5,
                            )
                          : null,
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          for (final tab in _tabs)
                            if (tab == t && (!tab.isStartPage || tab.behindStart != null))
                              Positioned.fill(
                                child: WebViewWidget(key: ValueKey(tab.id), controller: tab.controller),
                              ),
                          if (t.isStartPage)
                            Positioned.fill(
                              child: StartPage(
                                onOpen: (u) => t.load(u),
                                onSearchTap: _startEdit,
                                onOpenInNewTab: (u) => _newTab(url: u),
                                onOpenAll: _openAll,
                                onManage: _manageFavorites,
                                currentPage: t.currentPage,
                              ),
                            ),
                          if (_editing)
                            Positioned.fill(
                              child: _Suggestions(
                                query: _address.text,
                                data: _data,
                                onPick: (u) {
                                  _endEdit();
                                  t.load(u);
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (!_editing)
                      _BottomBar(
                        tab: t,
                        tabCount: _tabs.length,
                        downloading: _downloads.runningCount,
                        onBack: _back,
                        onForward: t.goForward,
                        onHome: t.showStartPage,
                        onTabs: _showTabs,
                        onMenu: _openMenu,
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

// -------------------------------------------------------------------- widgets

class _AddressBar extends StatelessWidget {
  const _AddressBar({
    required this.tab,
    required this.controller,
    required this.focus,
    required this.editing,
    required this.bookmarked,
    required this.onToggleFavorite,
    required this.onSubmit,
    required this.onStartEdit,
    required this.onCancel,
  });

  final VoidCallback onStartEdit;
  final VoidCallback onCancel;
  final BrowserTab tab;
  final TextEditingController controller;
  final FocusNode focus;
  final bool editing;
  final bool bookmarked;
  final VoidCallback onToggleFavorite;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    final secure = tab.url.startsWith('https://');
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(color: Palette.s2, borderRadius: BorderRadius.circular(22)),
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    Icon(
                      editing || tab.isStartPage
                          ? Icons.search_rounded
                          : (secure ? Icons.lock_outline_rounded : Icons.info_outline_rounded),
                      size: 17,
                      color: Palette.muted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: editing
                          ? TextField(
                              controller: controller,
                              focusNode: focus,
                              autofocus: true,
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.go,
                              autocorrect: false,
                              enableSuggestions: false,
                              style: const TextStyle(fontSize: 15),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isCollapsed: true,
                                hintText: '검색어 또는 주소 입력',
                              ),
                              onSubmitted: onSubmit,
                            )
                          : GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: onStartEdit,
                              child: SizedBox(
                                height: 44,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    tab.isStartPage ? '검색어 또는 주소 입력' : displayUrl(tab.url),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 15, color: tab.isStartPage ? Palette.dim : Palette.text),
                                  ),
                                ),
                              ),
                            ),
                    ),
                    if (editing && controller.text.isNotEmpty)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.cancel_rounded, size: 18, color: Palette.muted),
                        onPressed: controller.clear,
                      )
                    else if (!editing && !tab.isStartPage) ...[
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: bookmarked ? '즐겨찾기에서 빼기' : '즐겨찾기에 추가',
                        icon: Icon(
                          bookmarked ? Icons.star_rounded : Icons.star_outline_rounded,
                          size: 22,
                          color: bookmarked ? Palette.trim : Palette.muted,
                        ),
                        onPressed: onToggleFavorite,
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: tab.loading ? '중지' : '새로고침',
                        icon: Icon(tab.loading ? Icons.close_rounded : Icons.refresh_rounded, size: 20),
                        onPressed: tab.loading ? tab.stop : tab.reload,
                      ),
                    ] else
                      const SizedBox(width: 12),
                  ],
                ),
              ),
            ),
            if (editing) TextButton(onPressed: onCancel, child: const Text('취소')),
          ],
        ),
      ),
    );
  }
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.query, required this.data, required this.onPick});

  final String query;
  final BrowserData data;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final q = query.trim();
    final list = q.isEmpty ? data.history.take(8).toList() : data.suggestions(q);
    return Material(
      color: Palette.bg,
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          if (q.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.search_rounded, color: Palette.accent),
              title: Text(q, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                resolveInput(q, data.engine).startsWith(data.engine.prefix) ? '${data.engine.label}에서 검색' : '이 주소로 이동',
                style: const TextStyle(fontSize: 12, color: Palette.muted),
              ),
              onTap: () => onPick(resolveInput(q, data.engine)),
            ),
          if (q.isEmpty && list.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('최근 방문', style: TextStyle(fontSize: 12.5, color: Palette.muted)),
            ),
          for (final e in list)
            ListTile(
              leading: Icon(
                data.isBookmarked(e.url) ? Icons.star_rounded : Icons.history_rounded,
                color: Palette.dim,
                size: 20,
              ),
              title: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                displayUrl(e.url),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Palette.muted),
              ),
              onTap: () => onPick(e.url),
            ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.tab,
    required this.tabCount,
    required this.downloading,
    required this.onBack,
    required this.onForward,
    required this.onHome,
    required this.onTabs,
    required this.onMenu,
  });

  final BrowserTab tab;
  final int tabCount;
  final int downloading;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onHome;
  final VoidCallback onTabs;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final canBack = tab.canLeaveStartPage || (!tab.isStartPage && tab.canGoBack) || !tab.isStartPage;
    final canForward = !tab.isStartPage && tab.canGoForward;
    return Container(
      decoration: const BoxDecoration(
        color: Palette.s1,
        border: Border(top: BorderSide(color: Palette.line, width: .5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 54,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(
                tooltip: '뒤로',
                onPressed: canBack ? onBack : null,
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 21),
              ),
              IconButton(
                tooltip: '앞으로',
                onPressed: canForward ? onForward : null,
                icon: const Icon(Icons.arrow_forward_ios_rounded, size: 21),
              ),
              IconButton(tooltip: '홈', onPressed: onHome, icon: const Icon(Icons.home_outlined, size: 25)),
              IconButton(
                tooltip: '탭',
                onPressed: onTabs,
                icon: Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: Palette.text, width: 1.8),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    tabCount > 99 ? ':D' : '$tabCount',
                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              IconButton(
                tooltip: '메뉴',
                onPressed: onMenu,
                icon: Badge(
                  isLabelVisible: downloading > 0,
                  label: Text('$downloading'),
                  backgroundColor: Palette.accent,
                  child: const Icon(Icons.menu_rounded, size: 25),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickButton extends StatelessWidget {
  const _QuickButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.highlight = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1 : .35,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: [
              Icon(icon, color: highlight ? Palette.trim : Palette.text),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontSize: 12.5)),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.color,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    enabled: enabled,
    leading: Icon(icon, color: enabled ? color : null),
    title: Text(title, style: TextStyle(fontWeight: color != null ? FontWeight.w700 : null)),
    subtitle: subtitle == null ? null : Text(subtitle!, style: const TextStyle(fontSize: 12.5, color: Palette.muted)),
    onTap: onTap,
  );
}
