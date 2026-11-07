import 'package:flutter_test/flutter_test.dart';
import 'package:zamzam/browser/browser_tab.dart';
import 'package:zamzam/browser/video_sheet.dart';
import 'package:zamzam/core/browser_data.dart';
import 'package:zamzam/core/downloads.dart';
import 'package:zamzam/core/json_store.dart';
import 'package:zamzam/core/web_address.dart';

DownloadItem _item(String id, {String uri = 'content://media/1'}) => DownloadItem(
  id: id,
  uri: uri,
  name: '$id.mp4',
  sizeBytes: 10,
  sourceUrl: 'https://cdn.example.com/$id.mp4',
  pageUrl: 'https://example.com/page',
  time: DateTime(2026, 11, 7),
);

void main() {
  group('주소창 입력', () {
    const g = SearchEngine.google;

    test('주소처럼 보이면 https 를 붙여 연다', () {
      expect(resolveInput('naver.com', g), 'https://naver.com');
      expect(resolveInput('  m.youtube.com/watch?v=1 ', g), 'https://m.youtube.com/watch?v=1');
      expect(resolveInput('localhost:8080', g), 'https://localhost:8080');
      expect(resolveInput('192.168.0.1', g), 'https://192.168.0.1');
    });

    test('스킴이 있으면 그대로', () {
      expect(resolveInput('http://a.com', g), 'http://a.com');
      expect(resolveInput('https://a.com/x y', g), startsWith(g.prefix));
    });

    test('나머지는 검색', () {
      expect(
        resolveInput('고양이 동영상', g),
        'https://www.google.com/search?q=%EA%B3%A0%EC%96%91%EC%9D%B4+%EB%8F%99%EC%98%81%EC%83%81',
      );
      expect(resolveInput('flutter', SearchEngine.naver), 'https://search.naver.com/search.naver?query=flutter');
      expect(resolveInput('', g), '');
    });

    test('표시용 주소', () {
      expect(displayUrl('https://www.naver.com/'), 'naver.com');
      expect(displayUrl('http://a.com/b/'), 'a.com/b/');
      expect(hostOf('https://www.youtube.com/watch'), 'youtube.com');
    });
  });

  group('동영상 주소 판별', () {
    test('종류', () {
      expect(classifyVideoSource('https://a.com/v.mp4'), VideoSourceKind.file);
      expect(classifyVideoSource('https://a.com/play?id=3'), VideoSourceKind.file);
      expect(classifyVideoSource('blob:https://a.com/1234'), VideoSourceKind.stream);
      expect(classifyVideoSource('https://a.com/live/index.m3u8?t=1'), VideoSourceKind.hls);
      expect(classifyVideoSource('https://a.com/v/manifest.mpd'), VideoSourceKind.dash);
      expect(isDownloadable(VideoSourceKind.hls), isTrue);
      expect(isDownloadable(VideoSourceKind.stream), isFalse);
      expect(classifyVideoSource(''), VideoSourceKind.none);
      expect(classifyVideoSource('data:video/mp4;base64,AAA'), VideoSourceKind.none);
    });

    test('스트리밍이면 <source> 의 파일 주소를 쓴다', () {
      VideoHit hit(String src, List<String> sources) =>
          VideoHit(src: src, sources: sources, poster: '', durationSec: 0, title: '', page: '', userAgent: '');
      expect(downloadableSource(hit('blob:x', ['https://a.com/a.mp4'])), 'https://a.com/a.mp4');
      expect(downloadableSource(hit('https://a.com/b.webm', [])), 'https://a.com/b.webm');
      expect(downloadableSource(hit('blob:x', [])), isNull);
    });

    test('스트리밍이면 페이지가 받아 간 재생 목록을 쓴다', () {
      VideoHit hit(List<String> c) => VideoHit(
        src: 'blob:https://a.com/1',
        sources: const [],
        candidates: c,
        poster: '',
        durationSec: 0,
        title: '',
        page: '',
        userAgent: '',
      );
      expect(
        downloadableSource(hit(['https://a.com/x.mp4', 'https://cdn.a.com/v/master.m3u8?tok=1'])),
        'https://cdn.a.com/v/master.m3u8?tok=1',
      );
      expect(downloadableSource(hit(['https://a.com/api/list', 'https://a.com/clip.mp4'])), 'https://a.com/clip.mp4');
      expect(downloadableSource(hit(['https://a.com/api/list'])), isNull);
    });

    test('메시지 해석', () {
      final hit = VideoHit.parse(
        '{"type":"video","src":"https://a.com/v.mp4","sources":[],"poster":"","duration":12.5,'
        '"title":"T","page":"https://a.com","ua":"UA"}',
      );
      expect(hit!.src, 'https://a.com/v.mp4');
      expect(hit.durationSec, 12.5);
      expect(VideoHit.parse('not json'), isNull);
      expect(VideoHit.parse('{"type":"other"}'), isNull);
    });

    test('파일 이름', () {
      expect(suggestFileName(src: 'https://a.com/x/My%20Clip.mp4'), 'My Clip');
      expect(suggestFileName(src: 'https://a.com/v.mp4', title: '제목: a/b?'), '제목 a b');
      expect(suggestFileName(src: 'https://a.com/'), 'video');
      // 잘못 인코딩된 주소도 예외 없이 이름을 만든다.
      expect(suggestFileName(src: 'https://a.com/%E0%A4%A.mp4'), isNotEmpty);
      expect(suggestFileName(src: '', title: 'x' * 100).length, 60);
    });
  });

  group('브라우저 기록', () {
    test('방문 기록은 최근 것이 앞, 같은 주소는 하나만', () async {
      final file = MemoryJsonFile();
      final d = BrowserData(file: file);
      await d.load();
      d.addVisit('https://a.com', 'A');
      d.addVisit('https://b.com', 'B');
      d.addVisit('https://a.com', 'A2');
      expect(d.history.map((e) => e.url), ['https://a.com', 'https://b.com']);
      expect(d.history.first.title, 'A2');

      d.toggleBookmark('https://b.com', 'B');
      expect(d.isBookmarked('https://b.com'), isTrue);
      expect(d.suggestions('b').first.url, 'https://b.com');

      final again = BrowserData(file: file);
      await again.load();
      expect(again.history.length, 2);
      expect(again.bookmarks.single.title, 'B');

      d.clearHistory();
      expect(d.history, isEmpty);
      expect(d.bookmarks, isNotEmpty);
    });

    test('방문 기록 개수 제한', () async {
      final d = BrowserData(file: MemoryJsonFile());
      for (var i = 0; i < BrowserData.maxHistory + 5; i++) {
        d.addVisit('https://a.com/$i', '');
      }
      expect(d.history.length, BrowserData.maxHistory);
      expect(d.history.first.url, 'https://a.com/${BrowserData.maxHistory + 4}');
    });
  });

  group('다운로드 목록', () {
    test('추가·저장·불러오기', () async {
      final file = MemoryJsonFile();
      final d = Downloads(file: file, deleteAppCopy: (_) async {});
      await d.load();
      d.add(_item('a'));
      d.add(_item('b'));
      expect(d.items.map((e) => e.id), ['b', 'a']);

      final again = Downloads(file: file, deleteAppCopy: (_) async {});
      await again.load();
      expect(again.items.map((e) => e.id), ['b', 'a']);
      expect(again.items.last.sourceUrl, 'https://cdn.example.com/a.mp4');
    });

    test('이력 전부 지우기: 목록만 지우고 앱 폴더 사본만 삭제', () async {
      final deleted = <String>[];
      final file = MemoryJsonFile();
      final d = Downloads(file: file, deleteAppCopy: (p) async => deleted.add(p));
      await d.load();
      d.add(_item('android'));
      d.add(_item('ios', uri: '/var/mobile/app/Documents/downloads/x/ios.mp4'));
      await d.clearAll();
      expect(d.items, isEmpty);
      expect(deleted, ['/var/mobile/app/Documents/downloads/x/ios.mp4']);
      expect(file.value, isEmpty);
    });

    test('하나만 지우기', () async {
      final d = Downloads(file: MemoryJsonFile(), deleteAppCopy: (_) async {});
      d.add(_item('a'));
      d.add(_item('b'));
      await d.remove(d.items.first);
      expect(d.items.single.id, 'a');
    });
  });
}
