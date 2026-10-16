import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/media_engine.dart';
import '../core/time_format.dart';
import '../core/video_info.dart';
import 'export_flow.dart';
import 'theme.dart';
import 'video_view.dart';

/// 저장 전 미리보기: 고른 구간을 반복 재생하고, 왼쪽으로 90°씩 돌려 본 뒤 저장한다.
/// 저장하거나 닫으면 자르기 화면으로 돌아간다.
class TrimPreviewScreen extends StatefulWidget {
  const TrimPreviewScreen({
    super.key,
    required this.info,
    required this.startUs,
    required this.actualStartUs,
    required this.endUs,
  });

  final VideoInfo info;
  final int startUs;
  final int actualStartUs;
  final int endUs;

  @override
  State<TrimPreviewScreen> createState() => _TrimPreviewScreenState();
}

class _TrimPreviewScreenState extends State<TrimPreviewScreen> {
  VideoPlayerController? _ctrl;
  bool _failed = false;

  /// 왼쪽(반시계)으로 돌린 횟수(0~3).
  int _turns = 0;

  int get _lengthUs => widget.endUs - widget.actualStartUs;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final c = createController(widget.info.uri);
    try {
      await c.initialize();
      await c.seekTo(Duration(microseconds: widget.actualStartUs));
      c.addListener(_onTick);
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _ctrl = c);
      await c.play();
    } catch (_) {
      await c.dispose();
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  void _onTick() {
    final c = _ctrl;
    if (c == null || !mounted) return;
    final pos = c.value.position.inMicroseconds;
    // 구간 끝에 닿으면 처음으로 돌아가 계속 재생한다.
    if (c.value.isPlaying && (pos >= widget.endUs || pos < widget.actualStartUs - 200000)) {
      c.seekTo(Duration(microseconds: widget.actualStartUs));
    }
    setState(() {});
  }

  Future<void> _togglePlay() async {
    final c = _ctrl;
    if (c == null) return;
    c.value.isPlaying ? await c.pause() : await c.play();
  }

  Future<void> _save() async {
    await _ctrl?.pause();
    if (!mounted) return;
    final ok = await runExport(
      context,
      title: '새 동영상 만드는 중',
      job: () => MediaEngine.instance.trim(
        widget.info.uri,
        startUs: widget.startUs,
        endUs: widget.endUs,
        rotateCcw: _turns * 90,
      ),
    );
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('미리보기')),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, c) {
            if (isExpanded(c) && c.maxWidth > c.maxHeight * 0.9) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _stage()),
                    const SizedBox(width: 20),
                    SizedBox(width: 300, child: _panel()),
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _stage()),
                  const SizedBox(height: 12),
                  _panel(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// 영상 + 진행 표시. 회전은 화면에서 RotatedBox 로 보여주고, 저장할 때 파일의 회전 정보로 반영한다.
  Widget _stage() {
    final c = _ctrl;
    final ready = c != null && c.value.isInitialized;
    final pos = ready ? c.value.position.inMicroseconds : widget.actualStartUs;
    final rel = (pos - widget.actualStartUs).clamp(0, _lengthUs);
    final size = ready && c.value.size.width > 0 ? c.value.size : const Size(16, 9);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: GestureDetector(
        onTap: _togglePlay,
        child: Container(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (ready)
                FittedBox(
                  fit: BoxFit.contain,
                  child: RotatedBox(
                    quarterTurns: (4 - _turns) % 4,
                    child: SizedBox(width: size.width, height: size.height, child: VideoPlayer(c)),
                  ),
                )
              else if (_failed)
                const Center(
                  child: Text('미리보기를 열지 못했어요', style: TextStyle(color: Palette.muted)),
                )
              else
                const Center(child: CircularProgressIndicator()),
              if (ready && !c.value.isPlaying)
                Center(
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: const BoxDecoration(color: Color(0x73000000), shape: BoxShape.circle),
                    child: const Icon(Icons.play_arrow_rounded, size: 36, color: Colors.white),
                  ),
                ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: const Color(0x8C000000), borderRadius: BorderRadius.circular(7)),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: formatTime(rel)),
                            TextSpan(
                              text: ' / ${formatTime(_lengthUs)}',
                              style: const TextStyle(color: Color(0xFFAAAABB)),
                            ),
                          ],
                        ),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, fontFeatures: tabular),
                      ),
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _lengthUs == 0 ? 0 : rel / _lengthUs,
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(2),
                      color: Palette.trim,
                      backgroundColor: Colors.white24,
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

  Widget _panel() {
    final info = widget.info;
    final est = estimateBytes(info, widget.actualStartUs, widget.endUs);
    final degrees = _turns * 90;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _turns = (_turns + 1) % 4),
                icon: const Icon(Icons.rotate_left_rounded),
                label: const Text('왼쪽으로 90° 회전'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  foregroundColor: Palette.text,
                  side: const BorderSide(color: Palette.line, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Palette.s2, borderRadius: BorderRadius.circular(14)),
              child: Text(
                degrees == 0 ? '회전 없음' : '왼쪽 $degrees°',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: degrees == 0 ? Palette.muted : Palette.trim,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Panel(
          child: Column(
            children: [
              _kv('구간', '${formatTime(widget.actualStartUs)} ~ ${formatTime(widget.endUs)}'),
              _kv('길이', formatTime(_lengthUs)),
              _kv('예상 용량', '약 ${formatBytes(est)}'),
            ],
          ),
        ),
        const SizedBox(height: 14),
        PrimaryButton(label: '저장', icon: Icons.save_alt_rounded, onPressed: _save),
        const SizedBox(height: 8),
        const LosslessNote(trailing: '회전도 화질 손실 없이 저장돼요'),
      ],
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Text(k, style: const TextStyle(fontSize: 13, color: Palette.muted)),
        const Spacer(),
        Text(
          v,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, fontFeatures: tabular),
        ),
      ],
    ),
  );
}
