/// 웹 페이지에 넣는 스크립트.
library;

/// 페이지 → 앱 메시지 채널 이름.
const channelName = 'ZamZamBridge';

/// 동영상을 길게 누르면 그 동영상의 주소를 앱으로 보낸다.
///
/// 사이트가 재생 버튼·자막 같은 덮개를 동영상 위에 올려 두는 경우가 많아
/// 손가락 아래의 요소 대신 그 위치에 걸친 `<video>`를 직접 찾는다.
/// 같은 출처의 iframe 안 동영상도 찾는다(다른 출처는 브라우저가 막는다).
const longPressScript = r'''
(function () {
  if (window.__zzHook) return;
  window.__zzHook = true;
  var HOLD_MS = 550, SLOP = 12;
  var timer = null, sx = 0, sy = 0, firedAt = 0;

  function srcOf(v) {
    var s = v.currentSrc || v.src || '';
    var list = [];
    var nodes = v.querySelectorAll('source[src]');
    for (var i = 0; i < nodes.length; i++) list.push(nodes[i].src);
    if (!s && list.length) s = list[0];
    return { src: s, sources: list };
  }

  function hit(doc, x, y) {
    var els = doc.elementsFromPoint ? doc.elementsFromPoint(x, y) : [];
    for (var i = 0; i < els.length; i++) {
      var e = els[i];
      if (e.tagName === 'VIDEO') return e;
      if (e.tagName === 'IFRAME') {
        try {
          var r = e.getBoundingClientRect();
          var inner = e.contentDocument && hit(e.contentDocument, x - r.left, y - r.top);
          if (inner) return inner;
        } catch (err) {}
      }
    }
    var vids = doc.getElementsByTagName('video');
    for (var j = 0; j < vids.length; j++) {
      var b = vids[j].getBoundingClientRect();
      if (b.width > 0 && b.height > 0 && x >= b.left && x <= b.right && y >= b.top && y <= b.bottom) return vids[j];
    }
    return null;
  }

  function send(v) {
    var s = srcOf(v);
    try {
      ZamZamBridge.postMessage(JSON.stringify({
        type: 'video',
        src: s.src,
        sources: s.sources,
        poster: v.poster || '',
        duration: isFinite(v.duration) ? v.duration : 0,
        width: v.videoWidth || 0,
        height: v.videoHeight || 0,
        title: document.title || '',
        page: location.href,
        ua: navigator.userAgent
      }));
    } catch (err) {}
  }

  function clear() { if (timer) { clearTimeout(timer); timer = null; } }

  document.addEventListener('touchstart', function (e) {
    clear();
    if (e.touches.length !== 1) return;
    sx = e.touches[0].clientX; sy = e.touches[0].clientY;
    timer = setTimeout(function () {
      timer = null;
      var v = hit(document, sx, sy);
      if (v) { firedAt = Date.now(); send(v); }
    }, HOLD_MS);
  }, { capture: true, passive: true });

  document.addEventListener('touchmove', function (e) {
    if (!timer || !e.touches.length) return;
    var t = e.touches[0];
    if (Math.abs(t.clientX - sx) > SLOP || Math.abs(t.clientY - sy) > SLOP) clear();
  }, { capture: true, passive: true });
  document.addEventListener('touchend', clear, { capture: true, passive: true });
  document.addEventListener('touchcancel', clear, { capture: true, passive: true });

  // 동영상 위에서는 글자 선택·기본 메뉴가 뜨지 않게 한다.
  document.addEventListener('contextmenu', function (e) {
    if (Date.now() - firedAt < 1500 || hit(document, e.clientX, e.clientY)) e.preventDefault();
  }, true);
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
  return JSON.stringify(out);
})();
''';
