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

/// 즐겨찾기·방문 기록·설정. 바뀌면 바로 파일에 저장한다.
class BrowserData extends ChangeNotifier {
  BrowserData({JsonFile? file}) : _file = file ?? AppJsonFile('browser.json');

  /// 앱 전체에서 쓰는 하나. 테스트에서는 메모리 저장소로 바꿔 끼운다.
  static BrowserData instance = BrowserData();

  static const maxHistory = 1000;

  final JsonFile _file;

  /// 즐겨찾기. 새 탭 화면에 바로가기 칸으로 이 순서대로 보인다.
  final List<PageEntry> _bookmarks = [];
  final List<PageEntry> _history = [];
  SearchEngine _engine = SearchEngine.google;
  bool _desktop = false;
  bool _loaded = false;
  bool _seeded = false;

  static final defaultFavorites = [
    PageEntry(url: 'https://m.naver.com', title: '네이버', time: DateTime(2026)),
    PageEntry(url: 'https://www.google.com', title: '구글', time: DateTime(2026)),
    PageEntry(url: 'https://m.youtube.com', title: '유튜브', time: DateTime(2026)),
    PageEntry(url: 'https://m.daum.net', title: '다음', time: DateTime(2026)),
  ];

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
      _seeded = j['seeded'] == true;
      _history.addAll((j['history'] as List? ?? const []).map(PageEntry.fromJson).whereType<PageEntry>());
      _engine = SearchEngine.byName(j['engine'] as String?);
      _desktop = j['desktop'] == true;
    }
    // 처음 한 번은 자주 쓰는 사이트를 즐겨찾기에 넣어 둔다(지워도 다시 생기지 않는다).
    if (!_seeded) {
      _seeded = true;
      for (final d in defaultFavorites) {
        if (!isBookmarked(d.url)) _bookmarks.add(d);
      }
      _changed();
      return;
    }
    notifyListeners();
  }

  bool isBookmarked(String url) => _bookmarks.any((b) => b.url == url);

  void toggleBookmark(String url, String title) {
    if (isBookmarked(url)) {
      _bookmarks.removeWhere((b) => b.url == url);
    } else {
      _bookmarks.add(PageEntry(url: url, title: title, time: DateTime.now()));
    }
    _changed();
  }

  /// 즐겨찾기 추가(맨 뒤). 이미 있는 주소면 이름만 바꾼다.
  void addBookmark(String url, String title) {
    final i = _bookmarks.indexWhere((b) => b.url == url);
    if (i >= 0) {
      _bookmarks[i] = PageEntry(url: url, title: title, time: _bookmarks[i].time);
    } else {
      _bookmarks.add(PageEntry(url: url, title: title, time: DateTime.now()));
    }
    _changed();
  }

  /// [oldUrl] 즐겨찾기의 주소·이름을 바꾼다. 바꾼 주소가 다른 항목과 겹치면 그 항목은 지운다.
  void updateBookmark(String oldUrl, String url, String title) {
    final i = _bookmarks.indexWhere((b) => b.url == oldUrl);
    if (i < 0) return;
    final entry = PageEntry(url: url, title: title, time: _bookmarks[i].time);
    _bookmarks[i] = entry;
    for (var j = _bookmarks.length - 1; j >= 0; j--) {
      if (j != i && _bookmarks[j].url == url) _bookmarks.removeAt(j);
    }
    _changed();
  }

  /// 순서 바꾸기. [newIndex]는 [oldIndex] 항목을 뺀 뒤 넣을 자리.
  void moveBookmark(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _bookmarks.length) return;
    final e = _bookmarks.removeAt(oldIndex);
    _bookmarks.insert(newIndex.clamp(0, _bookmarks.length), e);
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

  /// 주소창 추천: 즐겨찾기 먼저, 그다음 방문 기록.
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
      'seeded': _seeded,
    });
  }
}
