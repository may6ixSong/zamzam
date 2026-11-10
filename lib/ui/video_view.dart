import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/native_player.dart';
import '../core/time_format.dart';
import 'theme.dart';

/// 플랫폼별 원본 위치로 플레이어를 만든다(Android content:// URI, iOS 파일 경로).
VideoPlayerController createController(String uri) {
  // 고친 사본(file://)은 파일로, 갤러리 영상(content://)은 그대로 연다.
  if (uri.startsWith('file://')) return VideoPlayerController.file(File(Uri.parse(uri).toFilePath()));
  return Platform.isAndroid ? VideoPlayerController.contentUri(Uri.parse(uri)) : VideoPlayerController.file(File(uri));
}

/// 안드로이드 기본 재생기로 다시 열어 볼지(테스트에서 바꾼다).
bool nativePreviewEnabled = Platform.isAndroid;

/// 미리보기 재생기를 연다. 기본 재생기(ExoPlayer)가 [timeout] 안에 준비되지 않거나 실패하면
/// 안드로이드 기본 재생기(MediaPlayer)로 다시 열어 본다. 둘 다 안 되면 null(정지 화면으로 편집).
/// 고장 난 재생기는 정리도 멈출 수 있어 기다리지 않는다.
Future<VideoPlayerController?> openPreviewPlayer(String uri, {Duration timeout = const Duration(seconds: 10)}) async {
  Future<VideoPlayerController?> attempt(VideoPlayerController ctrl) async {
    final ready = ctrl.initialize();
    try {
      await ready.timeout(timeout);
      return ctrl;
    } on TimeoutException {
      unawaited(ready.then((_) => ctrl.dispose(), onError: (_) => ctrl.dispose()).catchError((_) {}));
    } catch (_) {
      unawaited(ctrl.dispose().catchError((_) {}));
    }
    return null;
  }

  final first = await attempt(createController(uri));
  if (first != null) return first;
  if (!nativePreviewEnabled) return null;
  final native = VideoPlayerController.networkUrl(Uri.parse('${NativePlayerPlatform.scheme}$uri'));
  return attempt(native);
}

/// 16:9 틀 안에 영상을 맞춰 넣고, 가운데 재생 버튼과 왼쪽 아래 시간 표시를 얹는다.
class VideoView extends StatelessWidget {
  const VideoView({
    super.key,
    required this.controller,
    required this.positionUs,
    required this.durationUs,
    required this.onTogglePlay,
    this.label,
    this.still,
  });

  final VideoPlayerController? controller;
  final int positionUs;
  final int durationUs;
  final VoidCallback onTogglePlay;
  final String? label;

  /// 멈춰 있을 때 영상 대신 보여줄 그 시점 화면(JPEG).
  final Uint8List? still;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ready = c != null && c.value.isInitialized;
    final playing = ready && c.value.isPlaying;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: GestureDetector(
          onTap: ready ? onTogglePlay : null,
          child: Container(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (ready)
                  Center(
                    child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
                  )
                else
                  const Center(child: CircularProgressIndicator()),
                if (still != null && !playing)
                  Container(
                    color: Colors.black,
                    child: Image.memory(still!, fit: BoxFit.contain, gaplessPlayback: true),
                  ),
                if (ready && !playing)
                  Center(
                    child: Container(
                      width: 54,
                      height: 54,
                      decoration: const BoxDecoration(color: Color(0x73000000), shape: BoxShape.circle),
                      child: const Icon(Icons.play_arrow_rounded, size: 34, color: Colors.white),
                    ),
                  ),
                Positioned(
                  left: 10,
                  bottom: 9,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: const Color(0x8C000000), borderRadius: BorderRadius.circular(7)),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          if (label != null) TextSpan(text: '$label · '),
                          TextSpan(text: formatTime(positionUs)),
                          TextSpan(
                            text: ' / ${formatTime(durationUs)}',
                            style: const TextStyle(color: Color(0xFFAAAABB)),
                          ),
                        ],
                      ),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, fontFeatures: tabular),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 영상이 없을 때 가운데 안내.
class EmptyPrompt extends StatelessWidget {
  const EmptyPrompt({super.key, required this.icon, required this.text, required this.button, required this.onPressed});

  final IconData icon;
  final String text;
  final String button;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Palette.dim),
          const SizedBox(height: 14),
          Text(
            text,
            style: const TextStyle(fontSize: 15, color: Palette.muted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.video_library_outlined),
            label: Text(button),
            style: FilledButton.styleFrom(
              minimumSize: const Size(200, 50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    ),
  );
}
