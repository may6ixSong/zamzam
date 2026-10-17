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
import 'time_fields.dart';
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

  /// 시작·끝·재생 위치를 옮길 때 보여주는 그 시점 화면. 재생을 시작하면 지운다.
  Uint8List? _still;
  bool _stillBusy = false;
  (int, bool)? _stillPending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  int get _actualStart {
    final info = _info;
    if (info == null || info.exactCut) return _range.startUs;
    return keyframeAtOrBefore(info.keyframesUs, _range.startUs);
  }

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
        _still = null;
        _loading = false;
      });
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
    setState(() => _still = null);
    final pos = c.value.position.inMicroseconds;
    if (_loop && (pos < _actualStart || pos >= _range.endUs - 50000)) {
      await c.seekTo(Duration(microseconds: _actualStart));
    } else if (pos >= (_info?.durationUs ?? 0) - 50000) {
      await c.seekTo(Duration.zero);
    }
    await c.play();
  }

  // ---------------------------------------------------------------- range edits

  /// 그 시점 화면을 받아 영상 자리에 보여준다. 연달아 들어오면 직전 요청이 끝난 뒤 마지막 것만 처리해
  /// 손가락을 따라 화면이 계속 바뀐다. [exact]가 아니면 가까운 키프레임이라 빠르다.
  Future<void> _showFrame(int us, {bool exact = false}) async {
    final info = _info;
    if (info == null) return;
    if (_stillBusy) {
      _stillPending = (us, exact);
      return;
    }
    _stillBusy = true;
    (int, bool)? next = (us, exact);
    while (next != null) {
      final (t, e) = next;
      _stillPending = null;
      try {
        final bytes = await _engine.frameAt(info.uri, t, exact: e);
        if (!mounted || _info != info) break;
        if (bytes != null && !(_ctrl?.value.isPlaying ?? false)) setState(() => _still = bytes);
      } on PlatformException {
        // 화면 한 장을 못 받아도 편집은 계속할 수 있다.
      }
      next = _stillPending;
    }
    _stillBusy = false;
  }

  /// 범위를 바꾸고, [showUs] 또는 실제 시작([showStart]) 시점 화면을 보여준다.
  /// [settle]이면 정확한 프레임을 받고 재생 위치도 그곳으로 옮긴다(손을 뗐을 때·직접 입력했을 때).
  void _setRange(TrimRange r, {int? showUs, bool showStart = false, bool settle = true}) {
    _range = r;
    final show = showStart ? _actualStart : showUs;
    setState(() {
      if (show != null) _playhead = show;
    });
    if (show == null) return;
    _ctrl?.pause();
    _showFrame(show, exact: settle);
    if (settle) _seek(show);
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
        final r = moveStartSec(_range, us, info.durationUs);
        if (r != _range) _setRange(r, showUs: r.startUs, settle: false);
      case TimelineTarget.end:
        final r = moveEndSec(_range, us, info.durationUs);
        if (r != _range) _setRange(r, showUs: r.endUs, settle: false);
      case TimelineTarget.playhead:
        final p = us.clamp(0, info.durationUs);
        setState(() => _playhead = p);
        _showFrame(p);
    }
  }

  void _onDragEnd(TimelineTarget t) {
    _dragging = false;
    // 손을 떼면(또는 태그를 탭하면) 실제로 잘릴 시작/끝 프레임을 정확히 보여준다.
    switch (t) {
      case TimelineTarget.start:
        _setRange(_range, showStart: true);
      case TimelineTarget.end:
        _setRange(_range, showUs: _range.endUs);
      case TimelineTarget.playhead:
        _showFrame(_playhead, exact: true);
        _seek(_playhead);
    }
  }

  void _submitStart(int us) {
    final info = _info!;
    final r = moveStartSec(_range, us, info.durationUs);
    if (r.startUs != us) _toast('끝보다 최소 1초 앞이어야 해서 ${formatTime(r.startUs, decimals: 0)}(으)로 맞췄어요');
    _setRange(r, showStart: true);
  }

  void _submitEnd(int us) {
    final info = _info!;
    final r = moveEndSec(_range, us, info.durationUs);
    if (r.endUs ~/ usPerSecond != us ~/ usPerSecond) {
      _toast(
        us > info.durationUs
            ? '영상 길이를 넘어서 끝(${formatTime(r.endUs, decimals: 0)})으로 맞췄어요'
            : '시작보다 최소 1초 뒤여야 해서 ${formatTime(r.endUs, decimals: 0)}(으)로 맞췄어요',
      );
    }
    _setRange(r, showUs: r.endUs);
  }

  void _stepStart(int dir) {
    final r = moveStartSec(_range, _range.startUs + dir * usPerSecond, _info!.durationUs);
    _setRange(r, showStart: true);
  }

  void _stepEnd(int dir) {
    // 영상 끝(정수 초가 아닐 수 있음)에서 한 칸 앞으로 가면 그 아래 정수 초로.
    final base = dir < 0 && _range.endUs % usPerSecond != 0
        ? (_range.endUs ~/ usPerSecond + 1) * usPerSecond
        : _range.endUs;
    final r = moveEndSec(_range, base + dir * usPerSecond, _info!.durationUs);
    _setRange(r, showUs: r.endUs);
  }

  void _startHere() {
    final r = moveStartSec(_range, _playhead, _info!.durationUs);
    if ((r.startUs - _playhead).abs() >= usPerSecond) _toast('끝보다 최소 1초 앞이어야 해요');
    _setRange(r, showStart: true);
  }

  void _endHere() {
    final r = moveEndSec(_range, _playhead, _info!.durationUs);
    if ((r.endUs - _playhead).abs() >= usPerSecond) _toast('시작보다 최소 1초 뒤여야 해요');
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

  Widget _player() => VideoView(
    controller: _ctrl,
    positionUs: _playhead,
    durationUs: _info!.durationUs,
    onTogglePlay: _togglePlay,
    still: _still,
  );

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
      valueUs: _range.startUs,
      onSubmitted: _submitStart,
      onPrev: () => _stepStart(-1),
      onNext: () => _stepStart(1),
      onHere: _startHere,
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
    valueUs: _range.endUs,
    onSubmitted: _submitEnd,
    onPrev: () => _stepEnd(-1),
    onNext: () => _stepEnd(1),
    onHere: _endHere,
    sub: Text(_range.endUs == _info!.durationUs ? '영상 끝까지 포함해요' : '이 위치까지 포함해요'),
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
                    formatTime(len, decimals: 0),
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
    required this.valueUs,
    required this.onSubmitted,
    required this.onPrev,
    required this.onNext,
    required this.onHere,
    required this.sub,
  });

  final String label;
  final int valueUs;
  final ValueChanged<int> onSubmitted;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onHere;
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
        TimeFields(valueUs: valueUs, onSubmitted: onSubmitted),
        const SizedBox(height: 7),
        Row(
          children: [
            sq(const Icon(Icons.remove_rounded, size: 20), onPrev, '1초 앞으로'),
            const SizedBox(width: 6),
            sq(const Icon(Icons.add_rounded, size: 20), onNext, '1초 뒤로'),
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
