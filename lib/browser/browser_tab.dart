import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../core/media_engine.dart';

import '../core/browser_data.dart';
import 'page_scripts.dart';

/// 페이지에서 길게 누른 동영상.
class VideoHit {
  const VideoHit({
    required this.src,
    required this.sources,
    this.candidates = const [],
    required this.poster,
    required this.durationSec,
    this.width = 0,
    this.height = 0,
    required this.title,
    required this.page,
    required this.userAgent,
  });

  final String src;
  final List<String> sources;

  /// 페이지가 네트워크로 받아 간 영상 주소들(최근 것이 앞). 스트리밍일 때 이걸로 받는다.
  final List<String> candidates;
  final String poster;
  final double durationSec;

  /// 재생 중인 영상의 원본 해상도(모르면 0).
  final int width;
  final int height;
  final String title;
  final String page;
  final String userAgent;

  static VideoHit? parse(String message) {
    try {
      final j = jsonDecode(message);
      if (j is! Map || j['type'] != 'video') return null;
      return VideoHit(
        src: j['src'] as String? ?? '',
        sources: (j['sources'] as List? ?? const []).whereType<String>().toList(),
        candidates: (j['candidates'] as List? ?? const []).whereType<String>().toList(),
        poster: j['poster'] as String? ?? '',
        durationSec: (j['duration'] as num?)?.toDouble() ?? 0,
        width: (j['width'] as num?)?.toInt() ?? 0,
        height: (j['height'] as num?)?.toInt() ?? 0,
        title: j['title'] as String? ?? '',
        page: j['page'] as String? ?? '',
        userAgent: j['ua'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 브라우저 화면이 탭에 넘겨주는 창구(대화 상자, 외부 앱 열기 등).
abstract class TabHost {
  void onVideoHit(BrowserTab tab, VideoHit hit);
  Future<bool> openExternal(String url);
  Future<void> alert(String message);
  Future<bool> confirm(String message);
  Future<String?> prompt(String message, String defaultText);
  void showFullscreen(Widget widget, VoidCallback exit);
  void hideFullscreen();
  Future<List<String>> pickFiles(List<String> acceptTypes, bool multiple);
}

const desktopUserAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

/// 브라우저 탭 하나. 웹뷰 컨트롤러와 화면에 보여 줄 상태를 가진다.
class BrowserTab extends ChangeNotifier {
  // ignore: prefer_initializing_formals
  BrowserTab({required this.host, required this.data, required bool desktop}) : _desktop = desktop {
    controller = _createController();
  }

  static int _ids = 0;

  final int id = _ids++;
  final TabHost host;
  final BrowserData data;
  late final WebViewController controller;

  /// 비어 있으면 시작 페이지.
  String url = '';
  String title = '';
  int progress = 100;
  bool canGoBack = false;
  bool canGoForward = false;
  bool _desktop;
  bool _disposed = false;

  bool get isStartPage => url.isEmpty;
  bool get loading => progress < 100;

  WebViewController _createController() {
    final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }
    final c = WebViewController.fromPlatformCreationParams(params);
    c
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel(channelName, onMessageReceived: _onMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onPageStarted: (u) {
            url = u;
            progress = 5;
            _refreshNav();
          },
          onProgress: (p) {
            progress = p;
            _notify();
          },
          onPageFinished: (u) async {
            progress = 100;
            url = u;
            await _inject();
            // 이 탭에서 정한 화면 배율을 새 페이지에도 적용한다.
            if (zoom != 1.0) await _applyZoom();
            final t = await c.getTitle() ?? '';
            title = t;
            data.updateTitle(u, t);
            _refreshNav();
          },
          onUrlChange: (change) {
            final u = change.url;
            if (u == null || u == 'about:blank') return;
            url = u;
            data.addVisit(u, title);
            _refreshNav();
          },
        ),
      )
      ..setOnJavaScriptAlertDialog((r) => host.alert(r.message))
      ..setOnJavaScriptConfirmDialog((r) => host.confirm(r.message))
      ..setOnJavaScriptTextInputDialog((r) async => await host.prompt(r.message, r.defaultText ?? '') ?? '');
    if (_desktop) c.setUserAgent(desktopUserAgent);

    final p = c.platform;
    if (p is AndroidWebViewController) {
      p
        ..setMediaPlaybackRequiresUserGesture(false)
        ..setCustomWidgetCallbacks(
          onShowCustomWidget: (widget, exit) => host.showFullscreen(widget, exit),
          onHideCustomWidget: host.hideFullscreen,
        )
        ..setOnShowFileSelector(
          (params) => host.pickFiles(params.acceptTypes, params.mode == FileSelectorMode.openMultiple),
        );
      // iframe 안의 플레이어까지 잡도록 모든 프레임에 페이지 시작 시 넣는다.
      MediaEngine.instance.installPageScript(p.webViewIdentifier, longPressScript).catchError((_) => false);
      c.enableZoom(true);
    } else if (p is WebKitWebViewController) {
      p.setAllowsBackForwardNavigationGestures(true);
    }
    return c;
  }

  Future<NavigationDecision> _onNavigationRequest(NavigationRequest r) async {
    final scheme = Uri.tryParse(r.url)?.scheme.toLowerCase() ?? '';
    const web = {'http', 'https', 'about', 'data', 'blob', 'javascript', 'file'};
    if (scheme.isEmpty || web.contains(scheme)) return NavigationDecision.navigate;
    // intent:, tel:, mailto:, 앱 스킴 등은 해당 앱으로 넘긴다.
    await host.openExternal(r.url);
    return NavigationDecision.prevent;
  }

  void _onMessage(JavaScriptMessage m) {
    final hit = VideoHit.parse(m.message);
    if (hit != null) host.onVideoHit(this, hit);
  }

  Future<void> _inject() async {
    try {
      await controller.runJavaScript(longPressScript);
    } catch (e) {
      debugPrint('inject failed: $e');
    }
  }

  Future<void> _refreshNav() async {
    try {
      canGoBack = await controller.canGoBack();
      canGoForward = await controller.canGoForward();
    } catch (_) {}
    _notify();
  }

  Future<void> load(String target) async {
    if (target.isEmpty) return;
    behindStart = null;
    url = target;
    progress = 5;
    _notify();
    final uri = Uri.tryParse(target);
    if (uri == null) return;
    await controller.loadRequest(uri);
  }

  /// 화면 배율(1.0 = 100%). 탭마다 기억해 페이지를 옮겨도 유지한다.
  double zoom = 1.0;

  static const minZoom = 0.5;
  static const maxZoom = 3.0;

  /// 화면 배율을 바꾼다. 페이지 전체(글자·그림·iframe)를 CSS zoom 으로 키우거나 줄인다.
  Future<void> setZoom(double value) async {
    zoom = (value.clamp(minZoom, maxZoom) * 100).roundToDouble() / 100;
    _notify();
    await _applyZoom();
  }

  /// 원래 크기(100%)로.
  Future<void> fitZoom() => setZoom(1.0);

  Future<void> _applyZoom() async {
    if (isStartPage) return;
    final css = zoom == 1.0 ? '' : zoom.toString();
    try {
      await controller.runJavaScript("document.documentElement.style.zoom = '$css';");
    } catch (_) {}
  }

  /// 시작 페이지를 띄우기 전에 보던 주소. 뒤로 가기로 돌아간다.
  String? behindStart;

  /// [behindStart] 페이지의 제목.
  String behindTitle = '';

  /// 지금 보고 있는(시작 페이지면 그 뒤에 보던) 페이지. 없으면 null.
  PageEntry? get currentPage {
    final u = isStartPage ? behindStart : url;
    if (u == null || u.isEmpty || u == 'about:blank') return null;
    return PageEntry(url: u, title: isStartPage ? behindTitle : title, time: DateTime.now());
  }

  /// 시작 페이지로 돌아간다(웹 기록은 남겨 둔다).
  void showStartPage() {
    if (url.isNotEmpty) {
      behindStart = url;
      behindTitle = title;
    }
    controller
        .runJavaScript("document.querySelectorAll('video,audio').forEach(function(m){m.pause();});")
        .catchError((_) {});
    url = '';
    title = '';
    progress = 100;
    _notify();
  }

  bool get canLeaveStartPage => isStartPage && behindStart != null;

  /// 시작 페이지 → 보던 페이지, 아니면 웹 기록 뒤로.
  Future<void> goBack() async {
    if (canLeaveStartPage) {
      url = behindStart!;
      behindStart = null;
      title = await controller.getTitle() ?? '';
      _notify();
      return;
    }
    if (await controller.canGoBack()) await controller.goBack();
  }

  Future<void> goForward() async {
    if (await controller.canGoForward()) await controller.goForward();
  }

  Future<void> reload() => controller.reload();

  Future<void> stop() async {
    await controller.runJavaScript('window.stop();');
    progress = 100;
    _notify();
  }

  set desktopMode(bool v) {
    if (v == _desktop) return;
    _desktop = v;
    controller.setUserAgent(v ? desktopUserAgent : null);
    if (!isStartPage) controller.reload();
  }

  /// 페이지 안 동영상 주소 목록.
  Future<List<({String src, String kind, String poster})>> collectVideos() async {
    final r = await controller.runJavaScriptReturningResult(collectVideosScript);
    var text = r is String ? r : '$r';
    // Android 는 JSON 문자열을 한 번 더 따옴표로 감싸서 돌려준다.
    Object? j = jsonDecode(text);
    if (j is String) j = jsonDecode(j);
    if (j is! List) return const [];
    return [
      for (final e in j)
        if (e is Map && e['src'] is String)
          (src: e['src'] as String, kind: e['kind'] as String? ?? 'video', poster: e['poster'] as String? ?? ''),
    ];
  }

  Future<String> userAgent() async => await controller.getUserAgent() ?? '';

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
