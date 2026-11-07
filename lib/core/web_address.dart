/// 주소창 입력, 검색 엔진, 동영상 주소 판별 같은 브라우저의 순수 로직.
library;

enum SearchEngine {
  google('구글', 'https://www.google.com/search?q='),
  naver('네이버', 'https://search.naver.com/search.naver?query='),
  daum('다음', 'https://search.daum.net/search?q=');

  const SearchEngine(this.label, this.prefix);

  final String label;
  final String prefix;

  String searchUrl(String query) => '$prefix${Uri.encodeQueryComponent(query)}';

  static SearchEngine byName(String? name) =>
      SearchEngine.values.firstWhere((e) => e.name == name, orElse: () => SearchEngine.google);
}

final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');
final _hostLike = RegExp(r'^(localhost|[^\s/:]+\.[^\s/:]{2,}|\d{1,3}(\.\d{1,3}){3})(:\d+)?([/?#].*)?$');

/// 주소창에 쓴 글을 열 주소로 바꾼다. 주소처럼 보이지 않으면 [engine]으로 검색한다.
String resolveInput(String input, SearchEngine engine) {
  final s = input.trim();
  if (s.isEmpty) return '';
  if (_scheme.hasMatch(s) && !s.contains(' ')) {
    final lower = s.toLowerCase();
    if (lower.startsWith('http:') || lower.startsWith('https:') || lower.startsWith('about:')) return s;
    // localhost:8080 처럼 '이름:포트'도 스킴으로 읽히므로 따로 본다.
    if (_hostLike.hasMatch(s)) return 'https://$s';
    return s;
  }
  if (!s.contains(' ') && _hostLike.hasMatch(s)) return 'https://$s';
  return engine.searchUrl(s);
}

/// 주소창에 보여 줄 짧은 글(스킴·www 제거).
String displayUrl(String url) {
  var s = url;
  for (final p in const ['https://', 'http://']) {
    if (s.startsWith(p)) {
      s = s.substring(p.length);
      break;
    }
  }
  if (s.startsWith('www.')) s = s.substring(4);
  if (s.endsWith('/') && s.indexOf('/') == s.length - 1) s = s.substring(0, s.length - 1);
  return s;
}

String hostOf(String url) {
  final h = Uri.tryParse(url)?.host ?? '';
  return h.startsWith('www.') ? h.substring(4) : h;
}

/// 길게 누른 동영상 주소의 종류.
enum VideoSourceKind {
  /// 파일 주소라 그대로 내려받을 수 있다.
  file,

  /// blob: — 사이트가 조각을 이어 재생하는 스트리밍이라 파일이 없다.
  stream,

  /// .m3u8 — HLS 스트리밍. 조각을 받아 MP4 로 합칠 수 있다.
  hls,

  /// .mpd — DASH 스트리밍(지원하지 않음).
  dash,

  /// 주소가 없거나 알 수 없는 형식.
  none,
}

VideoSourceKind classifyVideoSource(String src) {
  final s = src.trim();
  if (s.isEmpty) return VideoSourceKind.none;
  final lower = s.toLowerCase();
  if (lower.startsWith('blob:') || lower.startsWith('mediasource:')) return VideoSourceKind.stream;
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) return VideoSourceKind.none;
  final path = (Uri.tryParse(s)?.path ?? '').toLowerCase();
  if (path.endsWith('.m3u8') || lower.contains('.m3u8?') || lower.contains('format=m3u8')) return VideoSourceKind.hls;
  if (path.endsWith('.mpd')) return VideoSourceKind.dash;
  return VideoSourceKind.file;
}

/// 받을 수 있는 종류인지(파일 또는 HLS).
bool isDownloadable(VideoSourceKind k) => k == VideoSourceKind.file || k == VideoSourceKind.hls;

/// 페이지가 받아 간 주소 중 영상일 가능성이 높은지. 재생 목록이나 영상 확장자가 있어야 한다.
bool isLikelyVideoResource(String url) {
  final k = classifyVideoSource(url);
  return k == VideoSourceKind.hls || (k == VideoSourceKind.file && looksLikeVideoFile(url));
}

const _videoExts = ['mp4', 'm4v', 'mov', 'webm', 'mkv', '3gp'];

/// 주소의 파일 이름이 동영상 확장자로 끝나는지.
bool looksLikeVideoFile(String url) {
  final path = (Uri.tryParse(url)?.path ?? '').toLowerCase();
  return _videoExts.any((e) => path.endsWith('.$e'));
}

/// 저장할 파일 이름(확장자 제외). 페이지 제목을 우선 쓰고, 없으면 주소의 파일 이름.
String suggestFileName({required String src, String? title}) {
  String clean(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  var base = clean(title ?? '');
  if (base.isEmpty) {
    // pathSegments 는 잘못 인코딩된 주소에서 예외를 던지므로 원문 경로를 직접 나눈다.
    final seg = (Uri.tryParse(src)?.path ?? '').split('/').where((e) => e.isNotEmpty).lastOrNull ?? '';
    final dot = seg.lastIndexOf('.');
    final raw = dot > 0 ? seg.substring(0, dot) : seg;
    String decoded;
    try {
      decoded = Uri.decodeComponent(raw);
    } catch (_) {
      decoded = raw;
    }
    base = clean(decoded);
  }
  if (base.isEmpty) base = 'video';
  if (base.length > 60) base = base.substring(0, 60).trim();
  return base;
}
