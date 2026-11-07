import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/downloads.dart';
import '../core/media_engine.dart';
import '../core/quality.dart';
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
    isScrollControlled: true,
    builder: (ctx) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .85),
      child: _VideoSheet(tab: tab, hit: hit),
    ),
  );
}

class _VideoSheet extends StatefulWidget {
  const _VideoSheet({required this.tab, required this.hit});

  final BrowserTab tab;
  final VideoHit hit;

  @override
  State<_VideoSheet> createState() => _VideoSheetState();
}

class _VideoSheetState extends State<_VideoSheet> {
  late final String? _src;
  late final VideoSourceKind _kind;
  late final String _name;

  /// 화질 목록. 알아보는 중이면 null.
  List<QualityOption>? _options;
  int _picked = 0;

  @override
  void initState() {
    super.initState();
    final hit = widget.hit;
    final found = downloadableSource(hit);
    final srcKind = found == null ? null : classifyVideoSource(found);
    _src = srcKind == VideoSourceKind.hls && !_hlsSupported ? null : found;
    _kind = _src != null ? srcKind! : (srcKind ?? classifyVideoSource(hit.src));
    _name = suggestFileName(src: _src ?? hit.src, title: hit.title.isNotEmpty ? hit.title : widget.tab.title);
    if (_src != null) _inspect(_src);
  }

  /// 화질 목록과 용량을 알아본다. 실패하면 '원본'만 보여 준다.
  Future<void> _inspect(String src) async {
    final hit = widget.hit;
    final android = defaultTargetPlatform == TargetPlatform.android;
    var info = VideoInspection(isHls: _kind == VideoSourceKind.hls);
    if (android) {
      try {
        final m = await MediaEngine.instance.inspectVideo(src, referer: hit.page, userAgent: hit.userAgent);
        info = VideoInspection.fromMap(m);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _options = qualityOptions(
        info,
        width: hit.width,
        height: hit.height,
        durationSec: hit.durationSec,
        canReencode: android,
      );
      _picked = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hit = widget.hit;
    final src = _src;
    final isHls = src != null && _kind == VideoSourceKind.hls;
    final options = _options;
    return SafeArea(
      child: SingleChildScrollView(
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
                        _name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (isHls) '스트리밍 → MP4',
                          if (hit.durationSec > 0) formatTime((hit.durationSec * 1e6).round(), decimals: 0),
                          hostOf(src ?? hit.page),
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12.5, color: Palette.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (src != null) ...[
              const Text('화질', style: TextStyle(fontSize: 13, color: Palette.muted)),
              const SizedBox(height: 6),
              if (options == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    children: [
                      SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 12),
                      Text('화질과 용량을 확인하는 중…', style: TextStyle(color: Palette.muted)),
                    ],
                  ),
                )
              else
                _QualityList(options: options, picked: _picked, onPick: (i) => setState(() => _picked = i)),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: options == null
                    ? null
                    : () {
                        final o = options[_picked];
                        Navigator.pop(context);
                        startVideoDownload(
                          url: src,
                          name: o.label == '원본' || options.length == 1 ? _name : '$_name ${o.label}',
                          pageUrl: hit.page,
                          userAgent: hit.userAgent,
                          variantUrl: o.variantUrl,
                          maxShortSide: o.maxShortSide,
                        );
                      },
                icon: const Icon(Icons.download_rounded),
                label: Text(
                  options == null ? '갤러리에 다운로드' : '${options[_picked].label} 다운로드',
                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                ),
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
                child: Text(switch (_kind) {
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
                  showPageVideos(context, widget.tab);
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

class _QualityList extends StatelessWidget {
  const _QualityList({required this.options, required this.picked, required this.onPick});

  final List<QualityOption> options;
  final int picked;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < options.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Material(
            color: i == picked ? Palette.s3 : Palette.s2,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onPick(i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: i == picked ? Palette.accent : Colors.transparent, width: 1.5),
                ),
                child: Row(
                  children: [
                    Icon(
                      i == picked ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      size: 20,
                      color: i == picked ? Palette.accent : Palette.dim,
                    ),
                    const SizedBox(width: 10),
                    Text(options[i].label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    if (options[i].reencode) ...[const SizedBox(width: 8), const Pill('변환')],
                    const Spacer(),
                    Text(
                      options[i].sizeBytes == null
                          ? (options[i].reencode ? '용량 예상 불가' : '')
                          : '${options[i].estimated ? '약 ' : ''}${formatBytes(options[i].sizeBytes!)}',
                      style: const TextStyle(color: Palette.muted, fontFeatures: tabular),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      if (options.any((o) => o.reencode))
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Text(
            '‘변환’은 받은 뒤 폰에서 해상도를 낮춰 다시 압축해요. 영상 길이에 따라 시간이 걸려요.',
            style: TextStyle(fontSize: 12, color: Palette.dim, height: 1.4),
          ),
        ),
    ],
  );
}

/// 내려받기를 시작하고, 끝나면 어느 화면에 있든 알려 준다.
void startVideoDownload({
  required String url,
  required String name,
  required String pageUrl,
  String? userAgent,
  String? variantUrl,
  int? maxShortSide,
}) {
  showToast(
    '다운로드를 시작했어요',
    action: SnackBarAction(label: '목록', onPressed: openDownloads),
    duration: const Duration(seconds: 1),
  );
  Downloads.instance
      .start(
        url: url,
        name: name,
        pageUrl: pageUrl,
        userAgent: userAgent,
        variantUrl: variantUrl,
        maxShortSide: maxShortSide,
      )
      .then((item) {
        if (item != null) {
          showToast(
            '갤러리에 저장했어요 · ${formatBytes(item.sizeBytes)}',
            action: SnackBarAction(label: '목록', onPressed: openDownloads),
            duration: const Duration(seconds: 1),
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
