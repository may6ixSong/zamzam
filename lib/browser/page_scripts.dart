/// 웹 페이지에 넣는 스크립트.
library;

/// 페이지 → 앱 메시지 채널 이름.
const channelName = 'ZamZamBridge';

/// 동영상을 길게 누르면 그 동영상의 주소를 앱으로 보낸다.
///
/// - 사이트가 재생 버튼·자막 같은 덮개를 동영상 위에 올려 두는 경우가 많아
///   손가락 아래의 요소 대신 그 위치에 걸친 `<video>`를 직접 찾는다(shadow DOM 안도 찾는다).
/// - Android 웹뷰는 약 0.5초에 자체 길게 누르기를 시작하며 터치를 취소하므로
///   타이머를 그보다 짧게 두고, 웹뷰가 보내는 contextmenu 이벤트로도 잡는다.
/// - 스트리밍 플레이어는 `<video>`에 blob: 주소만 남기므로, 페이지가 받아 간
///   재생 목록(.m3u8)·영상 파일 주소를 기록해 두었다가 함께 보낸다.
/// - Android 는 모든 프레임(iframe 포함)에 페이지 시작 시 넣고, 그 밖에는 페이지를 다 읽은 뒤 넣는다.
const longPressScript = r'''
(function () {
  if (window.__zzHook) return;
  window.__zzHook = true;
  var HOLD_MS = 380, SLOP = 14;
  var MEDIA = /\.(m3u8|mp4|m4v|webm|mov|mkv|mpd)(\?|#|$)|[?&](format|type)=(m3u8|hls|mp4)|\/manifest|playlist\.m3u8/i;
  var SKIP = /\.(m4s|ts|aac|vtt|srt|jpg|jpeg|png|gif|webp|js|css)(\?|#|$)|\/(ads?|doubleclick|googlesyndication)\b/i;
  var urls = [];

  function note(u) {
    try {
      if (!u) return;
      u = String(u.url || u);
      if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
      u = new URL(u, location.href).href;
      if (!MEDIA.test(u) || SKIP.test(u)) return;
      var i = urls.indexOf(u);
      if (i >= 0) urls.splice(i, 1);
      urls.push(u);
      if (urls.length > 60) urls.shift();
    } catch (e) {}
  }

  try {
    var xo = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (m, u) { note(u); return xo.apply(this, arguments); };
  } catch (e) {}
  try {
    if (window.fetch) {
      var fo = window.fetch;
      window.fetch = function (input) { note(input); return fo.apply(this, arguments); };
    }
  } catch (e) {}
  try { performance.setResourceTimingBufferSize(3000); } catch (e) {}

  function candidates() {
    try {
      var es = performance.getEntriesByType('resource');
      for (var i = 0; i < es.length; i++) note(es[i].name);
    } catch (e) {}
    return urls.slice().reverse();
  }
  window.__zzCandidates = candidates;

  function srcOf(v) {
    var s = v.currentSrc || v.src || '';
    var list = [];
    var nodes = v.querySelectorAll('source[src]');
    for (var i = 0; i < nodes.length; i++) list.push(nodes[i].src);
    if (!s && list.length) s = list[0];
    return { src: s, sources: list };
  }

  function allVideos(root, out) {
    var vids = root.querySelectorAll ? root.querySelectorAll('video') : [];
    for (var i = 0; i < vids.length; i++) out.push(vids[i]);
    var all = root.querySelectorAll ? root.querySelectorAll('*') : [];
    for (var j = 0; j < all.length; j++) if (all[j].shadowRoot) allVideos(all[j].shadowRoot, out);
    return out;
  }

  function inside(el, x, y) {
    var b = el.getBoundingClientRect();
    return b.width > 0 && b.height > 0 && x >= b.left && x <= b.right && y >= b.top && y <= b.bottom;
  }

  function hit(doc, x, y) {
    var els = doc.elementsFromPoint ? doc.elementsFromPoint(x, y) : [];
    for (var i = 0; i < els.length; i++) {
      var e = els[i];
      if (e.tagName === 'VIDEO') return e;
      if (e.shadowRoot && e.shadowRoot.elementsFromPoint) {
        var se = e.shadowRoot.elementsFromPoint(x, y);
        for (var k = 0; k < se.length; k++) if (se[k].tagName === 'VIDEO') return se[k];
      }
      if (e.tagName === 'IFRAME') {
        try {
          var r = e.getBoundingClientRect();
          var inner = e.contentDocument && hit(e.contentDocument, x - r.left, y - r.top);
          if (inner) return inner;
        } catch (err) {}
      }
    }
    var vids = allVideos(doc, []);
    for (var j = 0; j < vids.length; j++) if (inside(vids[j], x, y)) return vids[j];
    return null;
  }

  var firedAt = 0;
  function fire(x, y) {
    if (Date.now() - firedAt < 1200) return true;
    var v = hit(document, x, y);
    if (!v) return false;
    firedAt = Date.now();
    var s = srcOf(v);
    try {
      ZamZamBridge.postMessage(JSON.stringify({
        type: 'video',
        src: s.src,
        sources: s.sources,
        candidates: candidates(),
        poster: v.poster || '',
        duration: isFinite(v.duration) ? v.duration : 0,
        width: v.videoWidth || 0,
        height: v.videoHeight || 0,
        title: (window.top === window ? document.title : '') || '',
        page: location.href,
        ua: navigator.userAgent
      }));
    } catch (err) {}
    return true;
  }

  var timer = null, sx = 0, sy = 0;
  function clear() { if (timer) { clearTimeout(timer); timer = null; } }

  function install() {
    document.addEventListener('touchstart', function (e) {
      clear();
      if (e.touches.length !== 1) return;
      sx = e.touches[0].clientX; sy = e.touches[0].clientY;
      timer = setTimeout(function () { timer = null; fire(sx, sy); }, HOLD_MS);
    }, { capture: true, passive: true });
    document.addEventListener('touchmove', function (e) {
      if (!timer || !e.touches.length) return;
      var t = e.touches[0];
      if (Math.abs(t.clientX - sx) > SLOP || Math.abs(t.clientY - sy) > SLOP) clear();
    }, { capture: true, passive: true });
    document.addEventListener('touchend', clear, { capture: true, passive: true });
    document.addEventListener('touchcancel', clear, { capture: true, passive: true });
    // Android 웹뷰의 길게 누르기. 동영상 위라면 기본 메뉴·글자 선택을 막고 앱 시트를 띄운다.
    document.addEventListener('contextmenu', function (e) {
      if (fire(e.clientX, e.clientY)) { e.preventDefault(); e.stopPropagation(); }
    }, true);
  }
  install();
})();
''';

/// 페이지 안의 동영상 주소를 모두 모은다(길게 누르기가 안 되는 사이트용).
/// 결과는 JSON 문자열.
const collectVideosScript = r'''
(function () {
  var out = [], seen = {};
  function add(src, kind, poster) {
    if (!src || seen[src]) return;
    seen[src] = 1;
    out.push({ src: src, kind: kind, poster: poster || '' });
  }
  function scan(doc) {
    var vids = doc.getElementsByTagName('video');
    for (var i = 0; i < vids.length; i++) {
      var v = vids[i];
      add(v.currentSrc || v.src, 'video', v.poster);
      var ss = v.querySelectorAll('source[src]');
      for (var j = 0; j < ss.length; j++) add(ss[j].src, 'video', v.poster);
    }
    var links = doc.querySelectorAll('a[href]');
    for (var k = 0; k < links.length; k++) {
      var h = links[k].href || '';
      if (/\.(mp4|m4v|mov|webm|mkv|3gp)(\?|#|$)/i.test(h)) add(h, 'link', '');
    }
    var frames = doc.getElementsByTagName('iframe');
    for (var f = 0; f < frames.length; f++) {
      try { if (frames[f].contentDocument) scan(frames[f].contentDocument); } catch (e) {}
    }
  }
  scan(document);
  try {
    var c = window.__zzCandidates ? window.__zzCandidates() : [];
    for (var n = 0; n < c.length; n++) add(c[n], 'network', '');
  } catch (e) {}
  return JSON.stringify(out);
})();
''';
