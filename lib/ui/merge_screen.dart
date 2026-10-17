import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/media_engine.dart';
import '../core/time_format.dart';
import '../core/video_info.dart';
import 'export_flow.dart';
import 'theme.dart';
import 'video_view.dart';

class _Clip {
  _Clip(this.info) : key = UniqueKey();

  final VideoInfo info;
  final Key key;
  Uint8List? thumb;
}

class MergeScreen extends StatefulWidget {
  const MergeScreen({super.key});

  @override
  State<MergeScreen> createState() => _MergeScreenState();
}

class _MergeScreenState extends State<MergeScreen> {
  final _engine = MediaEngine.instance;
  final List<_Clip> _clips = [];
  int _selected = 0;
  bool _adding = false;

  VideoPlayerController? _preview;
  _Clip? _previewClip;
  bool _previewLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _add());
  }

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  /// 첫 번째 영상이 기준 형식. 각 영상이 기준과 다른 이유(없으면 빈 목록).
  List<List<String>> get _reasons {
    if (_clips.isEmpty) return const [];
    final base = _clips.first.info;
    return [
      for (final c in _clips) identical(c, _clips.first) ? const <String>[] : incompatibilityReasons(base, c.info),
    ];
  }

  Future<void> _add() async {
    List<String> uris;
    try {
      uris = await _engine.pickVideos(multiple: true);
    } on PlatformException catch (e) {
      _toast('갤러리를 열지 못했어요: ${e.message}');
      return;
    }
    if (uris.isEmpty) return;
    setState(() => _adding = true);
    var failed = 0;
    for (final uri in uris) {
      try {
        final clip = _Clip(await _engine.probe(uri));
        if (!mounted) return;
        setState(() => _clips.add(clip));
        _engine.thumbnails(uri, count: 1, height: 120).then((t) {
          if (mounted && t.isNotEmpty) setState(() => clip.thumb = t.first);
        });
      } on PlatformException {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _adding = false);
    if (failed > 0) _toast('$failed개 영상을 열지 못했어요');
  }

  void _remove(int i) {
    setState(() {
      _clips.removeAt(i);
      if (_selected >= _clips.length) _selected = (_clips.length - 1).clamp(0, 1 << 30);
    });
  }

  void _removeIncompatible() {
    final r = _reasons;
    setState(() {
      for (var i = _clips.length - 1; i >= 0; i--) {
        if (r[i].isNotEmpty) _clips.removeAt(i);
      }
      _selected = 0;
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final selectedClip = _clips.isEmpty ? null : _clips[_selected];
      final c = _clips.removeAt(oldIndex);
      _clips.insert(newIndex, c);
      if (selectedClip != null) _selected = _clips.indexOf(selectedClip);
    });
  }

  /// 확인을 받은 뒤 불러온 영상을 모두 비우고 새로 고른다(원본 파일은 그대로).
  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('처음부터 다시 할까요?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: Text(
          '불러온 동영상 ${_clips.length}개를 목록에서 모두 지워요.\n갤러리의 원본 파일은 지워지지 않아요.',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Palette.bad, foregroundColor: Colors.white),
            child: const Text('초기화'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final old = _preview;
    setState(() {
      _clips.clear();
      _selected = 0;
      _preview = null;
      _previewClip = null;
    });
    await old?.dispose();
    if (mounted) await _add();
  }

  Future<void> _loadPreview(_Clip clip) async {
    if (_previewLoading) return;
    _previewLoading = true;
    final old = _preview;
    setState(() {
      _preview = null;
      _previewClip = clip;
    });
    await old?.dispose();
    final ctrl = createController(clip.info.uri);
    try {
      await ctrl.initialize();
    } catch (_) {
      _previewLoading = false;
      await ctrl.dispose();
      return;
    }
    _previewLoading = false;
    if (!mounted || _previewClip != clip) {
      await ctrl.dispose();
      return;
    }
    ctrl.addListener(() {
      if (mounted) setState(() {});
    });
    setState(() => _preview = ctrl);
  }

  Future<void> _merge() async {
    await _preview?.pause();
    if (!mounted) return;
    await runExport(context, title: '동영상 합치는 중', job: () => _engine.merge([for (final c in _clips) c.info.uri]));
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
    return ConfirmLeave(
      enabled: _clips.isNotEmpty,
      message: '불러온 동영상 목록이 사라져요.',
      child: Scaffold(
        appBar: AppBar(
          title: const Text('동영상 합치기'),
          actions: [
            if (_clips.isNotEmpty)
              TextButton.icon(
                onPressed: _adding ? null : _reset,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('초기화'),
                style: TextButton.styleFrom(foregroundColor: Palette.muted),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: FilledButton.icon(
                onPressed: _adding ? null : _add,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('추가'),
                style: FilledButton.styleFrom(shape: const StadiumBorder(), foregroundColor: Colors.white),
              ),
            ),
          ],
          bottom: _adding
              ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator(minHeight: 3))
              : null,
        ),
        body: SafeArea(
          top: false,
          child: _clips.isEmpty
              ? (_adding
                    ? const Center(child: CircularProgressIndicator())
                    : EmptyPrompt(
                        icon: Icons.view_week_outlined,
                        text: '이어 붙일 동영상을 2개 이상 골라주세요',
                        button: '동영상 불러오기',
                        onPressed: _add,
                      ))
              : LayoutBuilder(builder: (context, c) => isExpanded(c) ? _expanded() : _compact()),
        ),
      ),
    );
  }

  Widget _compact() {
    final reasons = _reasons;
    return Column(
      children: [
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            buildDefaultDragHandles: false,
            header: const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('길게 눌러 끌면 순서를 바꿀 수 있어요', style: TextStyle(fontSize: 12, color: Palette.muted)),
            ),
            footer: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _afterList(reasons)),
            itemCount: _clips.length,
            onReorderItem: _reorder,
            itemBuilder: (_, i) => _tile(i, reasons[i], selectable: false),
          ),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 8), child: _actions(reasons)),
      ],
    );
  }

  Widget _expanded() {
    final reasons = _reasons;
    final clip = _clips[_selected.clamp(0, _clips.length - 1)];
    if (_previewClip != clip) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadPreview(clip);
      });
    }
    final good = [
      for (var i = 0; i < _clips.length; i++)
        if (reasons[i].isEmpty) i,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 10,
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              header: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Text('순서 (${_clips.length}개)', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    const Text('길게 눌러 끌어서 순서 변경', style: TextStyle(fontSize: 11.5, color: Palette.muted)),
                  ],
                ),
              ),
              footer: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [const SizedBox(height: 2), _baseFormat(), if (_hasBad(reasons)) _banner(reasons)],
              ),
              itemCount: _clips.length,
              onReorderItem: _reorder,
              itemBuilder: (_, i) => _tile(i, reasons[i], selectable: true),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            flex: 11,
            child: ListView(
              children: [
                VideoView(
                  controller: _preview,
                  positionUs: _preview?.value.position.inMicroseconds ?? 0,
                  durationUs: clip.info.durationUs,
                  label: '${_selected + 1}번',
                  onTogglePlay: () {
                    final p = _preview;
                    if (p == null) return;
                    p.value.isPlaying ? p.pause() : p.play();
                  },
                ),
                const SizedBox(height: 16),
                const Text('합쳐질 결과 미리보기', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                _sequenceBar(good),
                const SizedBox(height: 12),
                _summary(reasons),
                const SizedBox(height: 16),
                _actions(reasons),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _hasBad(List<List<String>> reasons) => reasons.any((r) => r.isNotEmpty);

  List<Widget> _afterList(List<List<String>> reasons) => [
    const SizedBox(height: 2),
    _baseFormat(),
    if (_hasBad(reasons)) _banner(reasons),
    const SizedBox(height: 10),
    _summary(reasons),
  ];

  Widget _tile(int i, List<String> reasons, {required bool selectable}) {
    final clip = _clips[i];
    final info = clip.info;
    final bad = reasons.isNotEmpty;
    final selected = selectable && i == _selected;
    return ReorderableDelayedDragStartListener(
      key: clip.key,
      index: i,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Material(
          color: bad ? const Color(0xFF1F1719) : Palette.s1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: bad
                  ? Palette.bad.withValues(alpha: .55)
                  : selected
                  ? Palette.accent
                  : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: selectable ? () => setState(() => _selected = i) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 9, 4, 9),
              child: Row(
                children: [
                  const Icon(Icons.drag_indicator_rounded, color: Color(0xFF5D636E), size: 20),
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: Palette.s3, shape: BoxShape.circle),
                    child: Text('${i + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 10),
                  _thumb(clip),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${info.resolutionLabel}${info.isPortrait ? ' (세로)' : ''} · ${info.codecLabel} · ${info.fpsLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: bad ? const Color(0xFFFF9B9B) : Palette.muted),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 3,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              formatBytes(info.sizeBytes),
                              style: const TextStyle(fontSize: 11, color: Palette.muted, fontFeatures: tabular),
                            ),
                            if (i == 0)
                              const Badge2.ok('기준')
                            else if (bad)
                              const Badge2.bad('형식 다름')
                            else
                              const Badge2.ok('호환됨'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '빼기',
                    onPressed: () => _remove(i),
                    icon: const Icon(Icons.close_rounded, size: 18, color: Palette.dim),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumb(_Clip clip) {
    final info = clip.info;
    final w = info.isPortrait ? 50.0 : 78.0;
    return SizedBox(
      width: 78,
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            width: w,
            height: 50,
            child: Stack(
              fit: StackFit.expand,
              children: [
                clip.thumb == null
                    ? Container(color: Palette.s3)
                    : Image.memory(clip.thumb!, fit: BoxFit.cover, gaplessPlayback: true),
                Positioned(
                  right: 4,
                  bottom: 3,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(color: const Color(0xA6000000), borderRadius: BorderRadius.circular(4)),
                    child: Text(
                      formatTime(info.durationUs, decimals: 0),
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, fontFeatures: tabular),
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

  Widget _baseFormat() {
    final b = _clips.first.info;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, size: 14, color: Palette.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '기준 형식: ${b.resolutionLabel} · ${b.codecLabel} · ${b.fpsLabel} · ${b.audioLabel} (1번 영상)',
              style: const TextStyle(fontSize: 11, color: Palette.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _banner(List<List<String>> reasons) {
    final badIdx = [
      for (var i = 0; i < reasons.length; i++)
        if (reasons[i].isNotEmpty) i,
    ];
    final title = badIdx.length == 1
        ? '${badIdx.first + 1}번 영상은 형식이 달라 이어붙일 수 없어요.'
        : '${badIdx.map((i) => '${i + 1}번').join(', ')} 영상은 형식이 달라 이어붙일 수 없어요.';
    final detail = badIdx.length == 1 ? '${reasons[badIdx.first].join(', ')}. ' : '';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
      decoration: BoxDecoration(
        color: Palette.bad.withValues(alpha: .1),
        border: Border.all(color: Palette.bad.withValues(alpha: .35)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: Palette.bad, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$title\n',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                  TextSpan(text: '$detail빼거나 같은 형식의 영상으로 바꿔주세요.'),
                ],
              ),
              style: const TextStyle(fontSize: 12, height: 1.5, color: Color(0xFFFFD0D0)),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _removeIncompatible,
            style: FilledButton.styleFrom(
              backgroundColor: Palette.bad,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 34),
            ),
            child: const Text('빼기', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _summary(List<List<String>> reasons) {
    var count = 0;
    var dur = 0;
    var size = 0;
    for (var i = 0; i < _clips.length; i++) {
      if (reasons[i].isNotEmpty) continue;
      count++;
      dur += _clips[i].info.durationUs;
      size += _clips[i].info.sizeBytes;
    }
    final badCount = _clips.length - count;
    Widget kv(String k, Widget v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(k, style: const TextStyle(fontSize: 13, color: Palette.muted)),
          const Spacer(),
          v,
        ],
      ),
    );
    const strong = TextStyle(fontSize: 13, fontWeight: FontWeight.w700, fontFeatures: tabular);
    const soft = TextStyle(fontSize: 13, color: Palette.muted);
    return Panel(
      child: Column(
        children: [
          kv(
            '합칠 영상',
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '$count개', style: strong),
                  if (badCount > 0) TextSpan(text: ' ($badCount개 제외 필요)', style: soft),
                ],
              ),
            ),
          ),
          kv('총 길이', Text(formatTime(dur, decimals: 0), style: strong)),
          kv(
            '예상 용량',
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '약 ${formatBytes(size)}', style: strong),
                  const TextSpan(text: ' = 원본 합계', style: soft),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sequenceBar(List<int> good) {
    if (good.isEmpty) return const SizedBox.shrink();
    var total = 0;
    final starts = <int>[];
    for (final i in good) {
      starts.add(total);
      total += _clips[i].info.durationUs;
    }
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            height: 34,
            child: Row(
              children: [
                for (var k = 0; k < good.length; k++) ...[
                  if (k > 0) const SizedBox(width: 3),
                  Expanded(
                    flex: (_clips[good[k]].info.durationUs ~/ 1000).clamp(1, 1 << 31),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _clips[good[k]].thumb == null
                            ? Container(color: Palette.s3)
                            : Opacity(
                                opacity: .85,
                                child: Image.memory(_clips[good[k]].thumb!, fit: BoxFit.cover, gaplessPlayback: true),
                              ),
                        Positioned(
                          left: 6,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: Text(
                              '${good[k] + 1}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                shadows: [Shadow(blurRadius: 3)],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Text('0:00', style: TextStyle(fontSize: 10.5, color: Palette.dim)),
            const Spacer(),
            Text(formatTick(total), style: const TextStyle(fontSize: 10.5, color: Palette.dim)),
          ],
        ),
      ],
    );
  }

  Widget _actions(List<List<String>> reasons) {
    final bad = _hasBad(reasons);
    final enough = _clips.length >= 2;
    final enabled = enough && !bad;
    return Column(
      children: [
        PrimaryButton(label: '동영상 합치기', icon: Icons.view_week_outlined, onPressed: enabled ? _merge : null),
        const SizedBox(height: 8),
        if (!enough)
          const Text('2개 이상 추가해주세요', style: TextStyle(fontSize: 11.5, color: Palette.muted))
        else if (bad)
          const Text('형식이 다른 영상을 빼면 합칠 수 있어요', style: TextStyle(fontSize: 11.5, color: Palette.muted))
        else
          const LosslessNote(),
      ],
    );
  }
}
