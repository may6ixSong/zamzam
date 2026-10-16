import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/media_engine.dart';
import '../core/time_format.dart';
import '../core/trim_range.dart';
import '../core/video_info.dart';
import 'theme.dart';
import 'trim_preview_screen.dart';
import 'trim_timeline.dart';
import 'video_view.dart';

class TrimScreen extends StatefulWidget {
  const TrimScreen({super.key});

  @override
  State<TrimScreen> createState() => _TrimScreenState();
}

class _TrimScreenState extends State<TrimScreen> {
  final _engine = MediaEngine.instance;

  VideoInfo? _info;
  VideoPlayerController? _ctrl;
  List<Uint8List> _thumbs = const [];
  TrimRange _range = const TrimRange(0, 0);
  int _playhead = 0;
  bool _loop = true;
  bool _loading = false;
  bool _dragging = false;

  bool _seeking = false;
  int? _pendingSeek;

  final _startText = TextEditingController();
  final _endText = TextEditingController();
  final _startFocus = FocusNode();
  final _endFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _startFocus.addListener(() {
      if (!_startFocus.hasFocus) _submitStart(_startText.text);
    });
    _endFocus.addListener(() {
      if (!_endFocus.hasFocus) _submitEnd(_endText.text);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    _startText.dispose();
    _endText.dispose();
    _startFocus.dispose();
    _endFocus.dispose();
    super.dispose();
  }

  int get _actualStart {
    final info = _info;
    if (info == null || info.exactCut) return _range.startUs;
    return keyframeAtOrBefore(info.keyframesUs, _range.startUs);
  }

  int get _frameUs => (usPerSecond / (_info?.fps ?? 30)).round();

  // ---------------------------------------------------------------- loading

  Future<void> _pick() async {
    List<String> uris;
    try {
      uris = await _engine.pickVideos(multiple: false);
    } on PlatformException catch (e) {
      _toast('갤러리를 열지 못했어요: ${e.message}');
      return;
    }
    if (uris.isEmpty) return;
    setState(() => _loading = true);
    try {
      final info = await _engine.probe(uris.first);
      if (!canTrim(info.durationUs)) {
        _toast('1초보다 짧은 영상은 자를 수 없어요');
        setState(() => _loading = false);
        return;
      }
      final old = _ctrl;
      final ctrl = createController(info.uri);
      await ctrl.initialize();
      ctrl.addListener(_onTick);
      await old?.dispose();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() {
        _info = info;
        _ctrl = ctrl;
        _thumbs = const [];
        _range = TrimRange(0, info.durationUs);
        _playhead = 0;
        _loading = false;
      });
      _syncTexts();
      final thumbs = await _engine.thumbnails(info.uri, count: 12, height: 120);
      if (mounted && _info == info) setState(() => _thumbs = thumbs);
    } on PlatformException catch (e) {
      setState(() => _loading = false);
      _toast('영상을 열지 못했어요: ${e.message}');
    }
  }

  // ---------------------------------------------------------------- playback

  void _onTick() {
    final c = _ctrl;
    if (c == null || !mounted) return;
    final pos = c.value.position.inMicroseconds;
    if (_loop && c.value.isPlaying && !_dragging && pos >= _range.endUs) {
      _seek(_actualStart);
    }
    if (!_dragging && !_seeking) {
      setState(() => _playhead = pos);
    } else {
      setState(() {});
    }
  }

  /// 빠르게 연달아 들어오는 탐색 요청은 직전 탐색이 끝난 뒤 마지막 것만 실행해
  /// 손가락을 따라 화면이 계속 갱신되게 한다.
  Future<void> _seek(int us) async {
    final c = _ctrl;
    if (c == null) return;
    if (_seeking) {
      _pendingSeek = us;
      return;
    }
    _seeking = true;
    var target = us;
    while (true) {
      await c.seekTo(Duration(microseconds: target));
      final next = _pendingSeek;
      _pendingSeek = null;
      if (next == null) break;
      target = next;
    }
    _seeking = false;
  }

  Future<void> _togglePlay() async {
    final c = _ctrl;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
      return;
    }
    final pos = c.value.position.inMicroseconds;
    if (_loop && (pos < _actualStart || pos >= _range.endUs - 50000)) {
      await c.seekTo(Duration(microseconds: _actualStart));
    } else if (pos >= (_info?.durationUs ?? 0) - 50000) {
      await c.seekTo(Duration.zero);
    }
    await c.play();
  }

  // ---------------------------------------------------------------- range edits

  /// [showStart]면 범위를 바꾼 뒤 실제 시작 프레임(키프레임)을 보여준다.
  void _setRange(TrimRange r, {int? showUs, bool showStart = false}) {
    _range = r;
    final show = showStart ? _actualStart : showUs;
    setState(() {
      if (show != null) _playhead = show;
    });
    _syncTexts();
    if (show != null) _seek(show);
  }

  void _syncTexts() {
    if (!_startFocus.hasFocus) _startText.text = formatTime(_range.startUs);
    if (!_endFocus.hasFocus) _endText.text = formatTime(_range.endUs);
  }

  void _onDragStart(TimelineTarget t) {
    _dragging = true;
    _ctrl?.pause();
    FocusScope.of(context).unfocus();
  }

  void _onDrag(TimelineTarget t, int us) {
    final info = _info!;
    switch (t) {
      case TimelineTarget.start:
        final r = moveStart(_range, us);
        _setRange(r, showUs: r.startUs);
      case TimelineTarget.end:
        final r = moveEnd(_range, us, info.durationUs);
        _setRange(r, showUs: r.endUs);
      case TimelineTarget.playhead:
        final p = us.clamp(0, info.durationUs);
        setState(() => _playhead = p);
        _seek(p);
    }
  }

  void _onDragEnd(TimelineTarget t) {
    _dragging = false;
    // 손을 떼면(또는 태그를 탭하면) 실제로 잘릴 시작/끝 프레임을 보여준다.
    if (t == TimelineTarget.start) _setRange(_range, showStart: true);
    if (t == TimelineTarget.end) _setRange(_range, showUs: _range.endUs);
  }

  void _submitStart(String text) {
    final info = _info;
    if (info == null) return;
    final v = parseTime(text);
    if (v == null) {
      _toast('시간 형식이 올바르지 않아요 (예: 1:12.4)');
      _syncTexts();
      return;
    }
    final r = moveStart(_range, v);
    if (r.startUs != v) _toast('끝보다 최소 1초 앞이어야 해서 ${formatTime(r.startUs)}(으)로 맞췄어요');
    _setRange(r, showStart: true);
  }

  void _submitEnd(String text) {
    final info = _info;
    if (info == null) return;
    final v = parseTime(text);
    if (v == null) {
      _toast('시간 형식이 올바르지 않아요 (예: 2:10.8)');
      _syncTexts();
      return;
    }
    final r = moveEnd(_range, v, info.durationUs);
    if (r.endUs != v) {
      _toast(
        v > info.durationUs
            ? '영상 길이를 넘어서 끝(${formatTime(r.endUs)})으로 맞췄어요'
            : '시작보다 최소 1초 뒤여야 해서 ${formatTime(r.endUs)}(으)로 맞췄어요',
      );
    }
    _setRange(r, showUs: r.endUs);
  }

  void _stepStart(int dir) {
    final info = _info!;
    int? target;
    if (info.exactCut || info.keyframesUs.isEmpty) {
      target = _range.startUs + dir * _frameUs;
    } else {
      target = dir < 0
          ? previousKeyframe(info.keyframesUs, _actualStart)
          : nextKeyframe(info.keyframesUs, _actualStart);
    }
    if (target == null) return;
    final r = moveStart(_range, target);
    _setRange(r, showStart: true);
  }

  void _stepEnd(int dir) {
    final r = moveEnd(_range, _range.endUs + dir * _frameUs, _info!.durationUs);
    _setRange(r, showUs: r.endUs);
  }

  void _startHere() {
    final r = moveStart(_range, _playhead);
    if (r.startUs != _playhead) _toast('끝보다 최소 1초 앞이어야 해요');
    _setRange(r, showStart: true);
  }

  void _endHere() {
    final r = moveEnd(_range, _playhead, _info!.durationUs);
    if (r.endUs != _playhead) _toast('시작보다 최소 1초 뒤여야 해요');
    _setRange(r, showUs: r.endUs);
  }

  Future<void> _export() async {
    final info = _info;
    if (info == null) return;
    FocusScope.of(context).unfocus();
    await _ctrl?.pause();
    if (!mounted) return;
    // 저장 전에 구간을 재생해 보고 회전할 수 있는 미리보기. 저장하거나 닫으면 이 화면 그대로 돌아온다.
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            TrimPreviewScreen(info: info, startUs: _range.startUs, actualStartUs: _actualStart, endUs: _range.endUs),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('동영상 자르기'),
        actions: [
          if (_info != null)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: ActionChip(
                avatar: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: const Text('다른 영상'),
                backgroundColor: Palette.s2,
                side: BorderSide.none,
                shape: const StadiumBorder(),
                onPressed: _loading ? null : _pick,
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _info == null
            ? EmptyPrompt(icon: Icons.content_cut_rounded, text: '자를 동영상을 골라주세요', button: '동영상 불러오기', onPressed: _pick)
            : LayoutBuilder(builder: (context, c) => isExpanded(c) ? _expanded() : _compact()),
      ),
    );
  }

  Widget _compact() {
    final info = _info!;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            children: [
              _fileInfoPills(info),
              if (info.looksTranscoded) ...[const SizedBox(height: 10), const TranscodeWarning()],
              const SizedBox(height: 10),
              _player(),
              const SizedBox(height: 8),
              _controls(),
              _timeline(52, 5, pagePadding: 16),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _startInput()),
                  const SizedBox(width: 10),
                  Expanded(child: _endInput()),
                ],
              ),
              const SizedBox(height: 12),
              _summary(),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          child: Column(
            children: [
              PrimaryButton(label: '새 동영상 만들기', icon: Icons.content_cut_rounded, onPressed: _export),
              const SizedBox(height: 8),
              const LosslessNote(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _expanded() {
    final info = _info!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 13, child: Column(children: [_player(), const SizedBox(height: 10), _controls()])),
            const SizedBox(width: 18),
            Expanded(
              flex: 7,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('원본', style: TextStyle(fontSize: 11.5, color: Palette.muted)),
                        const SizedBox(height: 4),
                        Text(info.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(
                          '${info.resolutionLabel} · ${info.codecLabel} · ${info.fpsLabel} · ${info.audioLabel}\n'
                          '${formatTime(info.durationUs)} · ${formatBytes(info.sizeBytes)}',
                          style: const TextStyle(fontSize: 11.5, color: Palette.muted, height: 1.6),
                        ),
                      ],
                    ),
                  ),
                  if (info.looksTranscoded) ...[const SizedBox(height: 12), const TranscodeWarning()],
                  const SizedBox(height: 12),
                  _summary(),
                  if (!info.exactCut) ...[
                    const SizedBox(height: 12),
                    const Panel(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Icon(Icons.info_outline_rounded, size: 15, color: Palette.muted),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '재인코딩 없이 자르기 때문에 시작점은 바로 앞 키프레임(타임라인 위 눈금)에 맞춰져요.',
                              style: TextStyle(fontSize: 11.5, color: Palette.muted, height: 1.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _timeline(84, 7, pagePadding: 22),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _startInput()),
            const SizedBox(width: 18),
            Expanded(child: _endInput()),
            const SizedBox(width: 18),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 21),
                child: Column(
                  children: [
                    PrimaryButton(label: '새 동영상 만들기', icon: Icons.content_cut_rounded, onPressed: _export, height: 92),
                    const SizedBox(height: 8),
                    const LosslessNote(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _fileInfoPills(VideoInfo info) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      Pill(info.name, strong: true),
      Pill(info.resolutionLabel),
      Pill('${info.codecLabel} · ${info.fpsLabel}'),
      Pill(formatBytes(info.sizeBytes)),
      Pill(formatTime(info.durationUs, decimals: 0)),
    ],
  );

  Widget _player() =>
      VideoView(controller: _ctrl, positionUs: _playhead, durationUs: _info!.durationUs, onTogglePlay: _togglePlay);

  Widget _controls() {
    final c = _ctrl;
    final playing = c?.value.isPlaying ?? false;
    final muted = (c?.value.volume ?? 1) == 0;
    return Row(
      children: [
        IconButton.filled(
          style: IconButton.styleFrom(backgroundColor: Palette.s2),
          onPressed: _togglePlay,
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Palette.text),
        ),
        const SizedBox(width: 6),
        FilterChip(
          selected: _loop,
          showCheckmark: false,
          avatar: Icon(Icons.repeat_rounded, size: 16, color: _loop ? Palette.trim : Palette.muted),
          label: Text('구간만 반복 재생', style: TextStyle(fontSize: 12, color: _loop ? Palette.trim : Palette.muted)),
          selectedColor: Palette.trim.withValues(alpha: .08),
          backgroundColor: Colors.transparent,
          side: BorderSide(color: _loop ? Palette.trim : Palette.line, width: 1.5),
          shape: const StadiumBorder(),
          onSelected: (v) => setState(() => _loop = v),
        ),
        const Spacer(),
        IconButton(
          onPressed: c == null ? null : () => c.setVolume(muted ? 1 : 0).then((_) => setState(() {})),
          icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: Palette.muted),
        ),
      ],
    );
  }

  /// [pagePadding]: 타임라인 바깥 화면 여백. 화면 끝의 '뒤로 가기' 제스처 영역과 겹치지 않게 안쪽을 더 비운다.
  Widget _timeline(double height, int ticks, {required double pagePadding}) {
    final info = _info!;
    final g = MediaQuery.systemGestureInsetsOf(context);
    final edge = math.max(math.max(g.left, g.right) + 10 - pagePadding, 0.0);
    return TrimTimeline(
      edgePadding: edge,
      durationUs: info.durationUs,
      startUs: _range.startUs,
      actualStartUs: _actualStart,
      endUs: _range.endUs,
      playheadUs: _playhead,
      thumbnails: _thumbs,
      keyframesUs: info.exactCut ? const [] : info.keyframesUs,
      stripHeight: height,
      tickCount: ticks,
      onDragStart: _onDragStart,
      onDrag: _onDrag,
      onDragEnd: _onDragEnd,
    );
  }

  Widget _startInput() {
    final info = _info!;
    final snapped = !info.exactCut && _actualStart != _range.startUs;
    return _TimeInput(
      label: '시작',
      controller: _startText,
      focusNode: _startFocus,
      onSubmitted: _submitStart,
      onPrev: () => _stepStart(-1),
      onNext: () => _stepStart(1),
      onHere: _startHere,
      stepTooltip: info.exactCut ? '한 프레임' : '키프레임',
      sub: snapped
          ? Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: '→ 실제 시작 '),
                  TextSpan(
                    text: formatTime(_actualStart),
                    style: const TextStyle(color: Palette.trim, fontWeight: FontWeight.w700),
                  ),
                  const TextSpan(text: ' (키프레임)'),
                ],
              ),
            )
          : Text(info.exactCut ? '이 위치부터 정확히 시작해요' : '키프레임 위치라 그대로 시작해요'),
    );
  }

  Widget _endInput() => _TimeInput(
    label: '끝',
    controller: _endText,
    focusNode: _endFocus,
    onSubmitted: _submitEnd,
    onPrev: () => _stepEnd(-1),
    onNext: () => _stepEnd(1),
    onHere: _endHere,
    stepTooltip: '한 프레임',
    sub: const Text('프레임 단위로 정확히 끝나요'),
  );

  Widget _summary() {
    final info = _info!;
    final len = _range.endUs - _actualStart;
    final est = estimateBytes(info, _actualStart, _range.endUs);
    final pct = info.sizeBytes <= 0 ? 0 : (100 * est / info.sizeBytes).round();
    return Panel(
      child: IntrinsicHeight(
        child: Row(
          children: [
            Expanded(
              flex: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('선택 구간', style: TextStyle(fontSize: 11.5, color: Palette.muted)),
                  Text(
                    formatTime(len),
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, fontFeatures: tabular),
                  ),
                ],
              ),
            ),
            const VerticalDivider(color: Palette.line, width: 24),
            Expanded(
              flex: 13,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('예상 용량', style: TextStyle(fontSize: 11.5, color: Palette.muted)),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '약 ${formatBytes(est)}',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, fontFeatures: tabular),
                    ),
                  ),
                  Text(
                    '원본 ${formatBytes(info.sizeBytes)}의 $pct%',
                    style: const TextStyle(fontSize: 11, color: Palette.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeInput extends StatelessWidget {
  const _TimeInput({
    required this.label,
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    required this.onPrev,
    required this.onNext,
    required this.onHere,
    required this.stepTooltip,
    required this.sub,
  });

  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onHere;
  final String stepTooltip;
  final Widget sub;

  @override
  Widget build(BuildContext context) {
    Widget sq(Widget child, VoidCallback onTap, String tip, {bool expand = false}) {
      final box = Tooltip(
        message: tip,
        child: Material(
          color: Palette.s2,
          borderRadius: BorderRadius.circular(11),
          child: InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: onTap,
            child: SizedBox(
              height: 42,
              width: expand ? null : 42,
              child: Center(child: child),
            ),
          ),
        ),
      );
      return expand ? Expanded(child: box) : box;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: Palette.trim, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: Palette.muted, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        const SizedBox(height: 7),
        TextField(
          controller: controller,
          focusNode: focusNode,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9:.]'))],
          textInputAction: TextInputAction.done,
          onSubmitted: onSubmitted,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, fontFeatures: tabular),
          cursorColor: Palette.trim,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Palette.s2,
            contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: const BorderSide(color: Palette.line, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: const BorderSide(color: Palette.trim, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 7),
        Row(
          children: [
            sq(const Icon(Icons.skip_previous_rounded, size: 20), onPrev, '이전 $stepTooltip'),
            const SizedBox(width: 6),
            sq(const Icon(Icons.skip_next_rounded, size: 20), onNext, '다음 $stepTooltip'),
            const SizedBox(width: 6),
            sq(
              const Text('현재 위치', maxLines: 1, style: TextStyle(fontSize: 12, color: Color(0xFFC8CCD4))),
              onHere,
              '재생 위치를 $label(으)로',
              expand: true,
            ),
          ],
        ),
        const SizedBox(height: 7),
        DefaultTextStyle(
          style: const TextStyle(fontSize: 11, color: Palette.muted),
          child: sub,
        ),
      ],
    );
  }
}
