import 'package:flutter/foundation.dart';

import 'json_store.dart';
import 'web_address.dart';

class PageEntry {
  const PageEntry({required this.url, required this.title, required this.time});

  final String url;
  final String title;
  final DateTime time;

  Map<String, Object?> toJson() => {'url': url, 'title': title, 't': time.millisecondsSinceEpoch};

  static PageEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final url = j['url'];
    if (url is! String || url.isEmpty) return null;
    return PageEntry(
      url: url,
      title: j['title'] as String? ?? '',
      time: DateTime.fromMillisecondsSinceEpoch((j['t'] as num?)?.toInt() ?? 0),
    );
  }

  String get label => title.trim().isEmpty ? displayUrl(url) : title.trim();
}

/// 북마크·방문 기록·설정. 바뀌면 바로 파일에 저장한다.
class BrowserData extends ChangeNotifier {
  BrowserData({JsonFile? file}) : _file = file ?? AppJsonFile('browser.json');

  static final BrowserData instance = BrowserData();

  static const maxHistory = 1000;

  final JsonFile _file;
  final List<PageEntry> _bookmarks = [];
  final List<PageEntry> _history = [];
  SearchEngine _engine = SearchEngine.google;
  bool _desktop = false;
  bool _loaded = false;

  List<PageEntry> get bookmarks => List.unmodifiable(_bookmarks);

  /// 최근 방문이 앞.
  List<PageEntry> get history => List.unmodifiable(_history);
  SearchEngine get engine => _engine;
  bool get desktopMode => _desktop;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final j = await _file.read();
    if (j is Map) {
      _bookmarks.addAll((j['bookmarks'] as List? ?? const []).map(PageEntry.fromJson).whereType<PageEntry>());
      _history.addAll((j['history'] as List? ?? const []).map(PageEntry.fromJson).whereType<PageEntry>());
      _engine = SearchEngine.byName(j['engine'] as String?);
      _desktop = j['desktop'] == true;
    }
    notifyListeners();
  }

  bool isBookmarked(String url) => _bookmarks.any((b) => b.url == url);

  void toggleBookmark(String url, String title) {
    if (isBookmarked(url)) {
      _bookmarks.removeWhere((b) => b.url == url);
    } else {
      _bookmarks.insert(0, PageEntry(url: url, title: title, time: DateTime.now()));
    }
    _changed();
  }

  void removeBookmark(String url) {
    _bookmarks.removeWhere((b) => b.url == url);
    _changed();
  }

  /// 같은 주소는 맨 앞으로 옮기고 제목을 새로 고친다.
  void addVisit(String url, String title, {DateTime? at}) {
    if (url.isEmpty || url == 'about:blank') return;
    _history.removeWhere((h) => h.url == url);
    _history.insert(0, PageEntry(url: url, title: title, time: at ?? DateTime.now()));
    if (_history.length > maxHistory) _history.removeRange(maxHistory, _history.length);
    _changed();
  }

  /// 페이지를 다 읽은 뒤 알게 된 제목을 반영한다.
  void updateTitle(String url, String title) {
    if (title.isEmpty) return;
    final i = _history.indexWhere((h) => h.url == url);
    if (i < 0 || _history[i].title == title) return;
    _history[i] = PageEntry(url: url, title: title, time: _history[i].time);
    _changed();
  }

  void removeVisit(String url) {
    _history.removeWhere((h) => h.url == url);
    _changed();
  }

  void clearHistory() {
    _history.clear();
    _changed();
  }

  set engine(SearchEngine e) {
    _engine = e;
    _changed();
  }

  set desktopMode(bool v) {
    _desktop = v;
    _changed();
  }

  /// 주소창 추천: 북마크 먼저, 그다음 방문 기록.
  List<PageEntry> suggestions(String query, {int limit = 8}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final seen = <String>{};
    final out = <PageEntry>[];
    for (final e in [..._bookmarks, ..._history]) {
      if (out.length >= limit) break;
      if (seen.contains(e.url)) continue;
      if (e.url.toLowerCase().contains(q) || e.title.toLowerCase().contains(q)) {
        seen.add(e.url);
        out.add(e);
      }
    }
    return out;
  }

  void _changed() {
    notifyListeners();
    _file.write({
      'bookmarks': _bookmarks.map((e) => e.toJson()).toList(),
      'history': _history.map((e) => e.toJson()).toList(),
      'engine': _engine.name,
      'desktop': _desktop,
    });
  }
}
