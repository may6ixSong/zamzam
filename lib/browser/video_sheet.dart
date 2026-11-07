import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/downloads.dart';
import '../core/time_format.dart';
import '../core/web_address.dart';
import '../ui/app_keys.dart';
import '../ui/downloads_screen.dart';
import '../ui/theme.dart';
import 'browser_tab.dart';

/// 내려받을 주소를 고른다.
///
/// 1. 재생 중인 주소나 `<source>`가 파일·HLS 면 그것.
/// 2. 스트리밍(blob:)이면 페이지가 받아 간 주소 중 HLS 재생 목록, 없으면 영상 파일.
String? downloadableSource(VideoHit hit) {
  for (final s in [hit.src, ...hit.sources]) {
    if (isDownloadable(classifyVideoSource(s))) return s;
  }
  for (final c in hit.candidates) {
    if (classifyVideoSource(c) == VideoSourceKind.hls) return c;
  }
  for (final c in hit.candidates) {
    if (isLikelyVideoResource(c)) return c;
  }
  return null;
}

/// iOS 는 아직 HLS 를 MP4 로 합치지 못한다.
bool get _hlsSupported => defaultTargetPlatform == TargetPlatform.android;

/// 동영상을 길게 눌렀을 때 뜨는 시트.
Future<void> showVideoSheet(BuildContext context, BrowserTab tab, VideoHit hit) {
  HapticFeedback.mediumImpact();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Palette.s1,
    showDragHandle: true,
    builder: (ctx) => _VideoSheet(tab: tab, hit: hit),
  );
}

class _VideoSheet extends StatelessWidget {
  const _VideoSheet({required this.tab, required this.hit});

  final BrowserTab tab;
  final VideoHit hit;

  @override
  Widget build(BuildContext context) {
    final found = downloadableSource(hit);
    final srcKind = found == null ? null : classifyVideoSource(found);
    final src = srcKind == VideoSourceKind.hls && !_hlsSupported ? null : found;
    final kind = src != null ? srcKind! : (srcKind ?? classifyVideoSource(hit.src));
    final isHls = src != null && kind == VideoSourceKind.hls;
    final name = suggestFileName(src: src ?? hit.src, title: hit.title.isNotEmpty ? hit.title : tab.title);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: Palette.s2, borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.movie_outlined, color: Palette.accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (isHls) '스트리밍 → MP4',
                          if (hit.durationSec > 0) formatTime((hit.durationSec * 1e6).round()),
                          hostOf(src ?? hit.page),
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12.5, color: Palette.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (src != null) ...[
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: () {
                  Navigator.pop(context);
                  startVideoDownload(url: src, name: name, pageUrl: hit.page, userAgent: hit.userAgent);
                },
                icon: const Icon(Icons.download_rounded),
                label: const Text('갤러리에 다운로드', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: src));
                  Navigator.pop(context);
                  showToast('동영상 주소를 복사했어요');
                },
                icon: const Icon(Icons.link_rounded),
                label: const Text('동영상 주소 복사'),
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Palette.s2, borderRadius: BorderRadius.circular(12)),
                child: Text(switch (kind) {
                  VideoSourceKind.stream =>
                    '스트리밍 주소를 아직 찾지 못했어요. 영상을 몇 초 재생한 뒤 다시 길게 눌러 보세요. '
                        '(유튜브처럼 영상·음성을 따로 암호화해 보내는 사이트는 받을 수 없어요)',
                  VideoSourceKind.hls => 'iOS 에서는 아직 스트리밍(HLS) 영상을 받을 수 없어요.',
                  VideoSourceKind.dash => 'DASH 방식 스트리밍이라 지금은 내려받을 수 없어요.',
                  _ => '동영상 주소를 찾지 못했어요. 한 번 재생한 뒤 다시 길게 눌러 보세요.',
                }, style: const TextStyle(fontSize: 13.5, height: 1.5, color: Palette.muted)),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                onPressed: () {
                  Navigator.pop(context);
                  showPageVideos(context, tab);
                },
                icon: const Icon(Icons.search_rounded),
                label: const Text('이 페이지의 다른 동영상 찾기'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 내려받기를 시작하고, 끝나면 어느 화면에 있든 알려 준다.
void startVideoDownload({required String url, required String name, required String pageUrl, String? userAgent}) {
  showToast(
    '다운로드를 시작했어요',
    action: SnackBarAction(label: '목록', onPressed: openDownloads),
  );
  Downloads.instance.start(url: url, name: name, pageUrl: pageUrl, userAgent: userAgent).then((item) {
    if (item != null) {
      showToast(
        '갤러리에 저장했어요 · ${formatBytes(item.sizeBytes)}',
        action: SnackBarAction(label: '목록', onPressed: openDownloads),
      );
    } else {
      final failed = Downloads.instance.tasks.where((t) => t.state == TaskState.failed && t.url == url);
      if (failed.isNotEmpty) {
        showToast(
          '다운로드하지 못했어요: ${failed.first.error}',
          action: SnackBarAction(label: '목록', onPressed: openDownloads),
        );
      }
    }
  });
}

void openDownloads() {
  final nav = navigatorKey.currentState;
  if (nav == null) return;
  nav.push(MaterialPageRoute(builder: (_) => const DownloadsScreen()));
}

/// 페이지 안의 동영상 목록을 보여 주고 고르면 내려받는다.
Future<void> showPageVideos(BuildContext context, BrowserTab tab) async {
  List<({String src, String kind, String poster})> found;
  try {
    found = await tab.collectVideos();
  } catch (e) {
    showToast('동영상을 찾지 못했어요');
    return;
  }
  final ua = await tab.userAgent();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Palette.s1,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                found.isEmpty ? '이 페이지에서 동영상을 찾지 못했어요' : '이 페이지의 동영상 ${found.length}개',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            if (found.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Text(
                  '영상을 몇 초 재생한 뒤 다시 찾아보거나, 영상 위를 길게 눌러 보세요.',
                  style: TextStyle(fontSize: 13.5, height: 1.5, color: Palette.muted),
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final v in found)
                    Builder(
                      builder: (_) {
                        final kind = classifyVideoSource(v.src);
                        final ok = isDownloadable(kind) && (kind != VideoSourceKind.hls || _hlsSupported);
                        return ListTile(
                          leading: Icon(
                            ok ? Icons.movie_outlined : Icons.block_rounded,
                            color: ok ? Palette.accent : Palette.dim,
                          ),
                          title: Text(
                            ok ? displayUrl(v.src) : (kind == VideoSourceKind.stream ? '스트리밍 영상' : displayUrl(v.src)),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13.5),
                          ),
                          subtitle: Text(
                            ok ? (kind == VideoSourceKind.hls ? '스트리밍 · 눌러서 MP4 로 다운로드' : '눌러서 다운로드') : '내려받을 수 없는 방식',
                            style: const TextStyle(fontSize: 12, color: Palette.muted),
                          ),
                          enabled: ok,
                          onTap: () {
                            Navigator.pop(ctx);
                            startVideoDownload(
                              url: v.src,
                              name: suggestFileName(src: v.src, title: found.length == 1 ? tab.title : null),
                              pageUrl: tab.url,
                              userAgent: ua,
                            );
                          },
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
