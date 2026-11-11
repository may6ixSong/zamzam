import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/crop_rect.dart';
import '../core/media_engine.dart';
import '../core/time_format.dart';
import '../core/trim_range.dart';
import '../core/video_info.dart';
import 'export_flow.dart';
import 'menu_screen.dart';
import 'theme.dart';
import 'trash_flow.dart';
import 'video_view.dart';

/// 크기 자르기: 화면을 돌리고(90도씩) 남길 영역을 정해 다시 압축해 저장한다.
/// 남는 면적 비율만큼 압축 크기를 줄여 원본보다 커지지 않게 한다.
class CropScreen extends StatefulWidget {
  const CropScreen({super.key, this.initialUri});

  /// 주면 갤러리 선택 없이 이 영상을 바로 연다(다운로드 목록에서 들어올 때).
  final String? initialUri;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  final _engine = MediaEngine.instance;

  VideoInfo? _info;

  /// 갤러리의 원본(고친 사본으로 편집해도 휴지통에는 이걸 옮긴다).
  String? _sourceUri;
  bool _loading = false;
  String _loadingStep = '';

  /// 화면을 왼쪽(반시계)으로 돌린 횟수(0~3).
  int _turns = 0;
  CropAspect _aspect = CropAspect.free;
  CropRect _rect = CropRect.full;

  /// 미리 보는 장면 시각과 그 화면.
  int _frameUs = 0;
  Uint8List? _frame;
  bool _frameBusy = false;
  int? _framePending;

  @override
  void initState() {
    super.initState();
    final first = widget.initialUri;
    WidgetsBinding.instance.addPostFrameCallback((_) => first != null ? _load(first) : _pick());
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
    await _load(uris.first);
  }

  /// 영상 정보를 읽는다. 소리·키프레임이 깨진 파일(브라우저로 받은 스트리밍 영상)이면
  /// 고친 사본을 만들어 그걸로 연다.
  Future<void> _load(String uri, {bool repaired = false}) async {
    if (!repaired) _sourceUri = uri;
    setState(() {
      _loading = true;
      _loadingStep = '영상 정보를 읽는 중…';
    });
    try {
      var info = await _engine.probe(uri);
      if (!repaired &&
          needsRepair(
            keyframesUs: info.keyframesUs,
            durationUs: info.durationUs,
            fps: info.fps,
            audioAdts: info.audioAdts,
          )) {
        setState(() => _loadingStep = '영상을 정리하는 중…');
        info = await _engine.probe(await _engine.repair(uri));
      }
      if (!mounted) return;
      setState(() {
        _info = info;
        _turns = 0;
        _aspect = CropAspect.free;
        _rect = CropRect.full;
        _frameUs = 0;
        _frame = null;
        _loading = false;
      });
      _showFrame(0, exact: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('영상을 열지 못했어요: ${e is PlatformException ? e.message : e}');
    }
  }

  /// 그 시점 화면을 받아 보여 준다. 연달아 들어오면 마지막 요청만 처리한다.
  Future<void> _showFrame(int us, {bool exact = false}) async {
    final info = _info;
    if (info == null) return;
    if (_frameBusy) {
      _framePending = us;
      return;
    }
    _frameBusy = true;
    int? next = us;
    while (next != null) {
      _framePending = null;
      try {
        final bytes = await _engine.frameAt(info.uri, next, height: 720, exact: exact);
        if (!mounted || _info != info) break;
        if (bytes != null) setState(() => _frame = bytes);
      } on PlatformException {
        // 화면 한 장을 못 받아도 영역은 정할 수 있다.
      }
      next = _framePending;
    }
    _frameBusy = false;
  }

  // ---------------------------------------------------------------- geometry

  /// 화면에 보이는 방향(파일 회전 반영)의 가로·세로.
  (int, int) get _displaySize {
    final info = _info!;
    return info.rotation % 180 != 0 ? (info.height, info.width) : (info.width, info.height);
  }

  /// 사용자가 돌린 뒤의 가로·세로.
  (int, int) get _turnedSize {
    final (w, h) = _displaySize;
    return _turns.isOdd ? (h, w) : (w, h);
  }

  double get _frameAspect {
    final (w, h) = _turnedSize;
    return h == 0 ? 16 / 9 : w / h;
  }

  /// 비율 고정일 때 영역의 정규화 비율(픽셀 비율 / 화면 비율).
  double? get _normRatio {
    final r = switch (_aspect) {
      CropAspect.free => null,
      CropAspect.original => _frameAspect,
      _ => _aspect.ratio,
    };
    return r == null ? null : r / _frameAspect;
  }

  void _setAspect(CropAspect a) {
    setState(() {
      _aspect = a;
      _rect = switch (a) {
        CropAspect.free || CropAspect.original => CropRect.full,
        _ => CropRect.fit(a.ratio!, _frameAspect),
      };
    });
  }

  void _rotate() {
    setState(() {
      _turns = (_turns + 1) % 4;
      // 돌리면 화면 모양이 바뀌므로 영역을 다시 맞춘다.
      _rect = _aspect.ratio == null ? CropRect.full : CropRect.fit(_aspect.ratio!, _frameAspect);
    });
  }

  void _reset() => setState(() {
    _turns = 0;
    _aspect = CropAspect.free;
    _rect = CropRect.full;
  });

  bool get _changed => _turns != 0 || !_rect.isFull;

  // ---------------------------------------------------------------- export

  Future<void> _export() async {
    final info = _info;
    if (info == null || !_changed) return;
    final base = info.name.contains('.') ? info.name.substring(0, info.name.lastIndexOf('.')) : info.name;
    await runExport(
      context,
      title: '크기 자르는 중',
      detail: '다시 압축하는 중',
      job: () => _engine.crop(info.uri, crop: _rect.toList(), rotateCcw: _turns * 90, name: base),
    );
  }

  Future<void> _trashOriginal() async {
    final src = _sourceUri;
    if (src == null) return;
    final moved = await confirmAndTrash(context, uris: [src], what: '원본 영상', keeps: '이미 잘라서 저장한 영상은 그대로 남아요.');
    if (!moved || !mounted) return;
    // 원본이 없어졌으니 편집 메뉴로 돌아간다.
    MenuScreen.backTo(context);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return ConfirmLeave(
      enabled: _info != null && _changed,
      message: '정해 둔 영역과 회전이 사라져요.',
      child: Scaffold(
        appBar: AppBar(
          title: const Text('크기 자르기'),
          actions: [
            if (_info != null && !_loading)
              IconButton(
                tooltip: '원본 영상을 휴지통으로',
                onPressed: _trashOriginal,
                icon: const Icon(Icons.delete_outline_rounded, color: Palette.bad),
              ),
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
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(_loadingStep, style: const TextStyle(color: Palette.muted)),
                    ],
                  ),
                )
              : _info == null
              ? EmptyPrompt(icon: Icons.crop_rounded, text: '크기를 자를 동영상을 골라주세요', button: '동영상 불러오기', onPressed: _pick)
              : LayoutBuilder(builder: (context, c) => isExpanded(c) ? _expanded() : _compact()),
        ),
      ),
    );
  }

  Widget _compact() => Column(
    children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: _pills()),
      Expanded(
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _canvas()),
      ),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _scrubber()),
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 0), child: _tools()),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Column(
          children: [
            _summary(),
            const SizedBox(height: 10),
            _button(),
            const SizedBox(height: 8),
            const _ReencodeNote(),
          ],
        ),
      ),
    ],
  );

  Widget _expanded() => Padding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            children: [
              Expanded(child: _canvas()),
              _scrubber(),
            ],
          ),
        ),
        const SizedBox(width: 24),
        SizedBox(
          width: 340,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _pills(),
              const SizedBox(height: 16),
              _tools(),
              const SizedBox(height: 16),
              _summary(),
              const Spacer(),
              _button(),
              const SizedBox(height: 8),
              const _ReencodeNote(),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _pills() {
    final info = _info!;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        Pill(info.name, strong: true),
        Pill(info.resolutionLabel),
        Pill(formatBytes(info.sizeBytes)),
        Pill(formatTime(info.durationUs, decimals: 0)),
      ],
    );
  }

  Widget _canvas() => Center(
    child: AspectRatio(
      aspectRatio: _frameAspect,
      child: CropCanvas(
        frame: _frame,
        turns: _turns,
        rect: _rect,
        normRatio: _normRatio,
        onChanged: (r) => setState(() => _rect = r),
      ),
    ),
  );

  Widget _scrubber() {
    final dur = _info!.durationUs;
    return Row(
      children: [
        const SizedBox(width: 8),
        const Icon(Icons.image_outlined, size: 18, color: Palette.muted),
        Expanded(
          child: Slider(
            value: _frameUs.clamp(0, dur).toDouble(),
            max: dur.toDouble().clamp(1, double.infinity),
            onChanged: (v) {
              setState(() => _frameUs = v.round());
              _showFrame(v.round());
            },
            onChangeEnd: (v) => _showFrame(v.round(), exact: true),
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(
            formatTime(_frameUs, decimals: 0),
            style: const TextStyle(fontSize: 12.5, color: Palette.muted, fontFeatures: tabular),
          ),
        ),
      ],
    );
  }

  Widget _tools() {
    final chips = [
      for (final a in CropAspect.values)
        ChoiceChip(
          label: Text(a.label),
          selected: _aspect == a,
          onSelected: (_) => _setAspect(a),
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
        ),
    ];
    final rotate = OutlinedButton.icon(
      onPressed: _rotate,
      icon: const Icon(Icons.rotate_left_rounded, size: 20),
      label: Text(_turns == 0 ? '회전' : '${_turns * 90}°'),
    );
    final reset = IconButton(
      tooltip: '처음대로',
      onPressed: _changed ? _reset : null,
      icon: const Icon(Icons.restart_alt_rounded),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [rotate, const Spacer(), reset]),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: chips),
      ],
    );
  }

  Widget _summary() {
    final info = _info!;
    final (tw, th) = _turnedSize;
    final (ow, oh) = cropOutputSize(tw, th, _rect);
    final bytes = estimateCropBytes(
      videoBytes: info.videoBytes ?? info.sizeBytes,
      audioBytes: info.audioBytes ?? 0,
      rect: _rect,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(color: Palette.s1, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('결과 크기', style: TextStyle(fontSize: 12.5, color: Palette.muted)),
                const SizedBox(height: 2),
                Text(
                  '$ow×$oh',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, fontFeatures: tabular),
                ),
              ],
            ),
          ),
          Container(width: 1, height: 36, color: Palette.line),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('예상 용량', style: TextStyle(fontSize: 12.5, color: Palette.muted)),
                const SizedBox(height: 2),
                Text(
                  '약 ${formatBytes(bytes)}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, fontFeatures: tabular),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _button() => PrimaryButton(
    label: _changed ? '새 동영상 만들기' : '영역을 정하거나 돌려 주세요',
    icon: Icons.crop_rounded,
    onPressed: _changed ? _export : null,
  );
}

class _ReencodeNote extends StatelessWidget {
  const _ReencodeNote();

  @override
  Widget build(BuildContext context) => const Text(
    '다시 압축해서 저장해요 · 원본보다 커지지 않게 · 원본은 그대로',
    textAlign: TextAlign.center,
    style: TextStyle(fontSize: 12, color: Palette.dim),
  );
}

/// 장면 위에 남길 영역 상자를 그리고, 끌어서 옮기거나(안쪽) 크기를 바꾼다(모서리).
class CropCanvas extends StatefulWidget {
  const CropCanvas({
    super.key,
    required this.frame,
    required this.turns,
    required this.rect,
    required this.normRatio,
    required this.onChanged,
  });

  final Uint8List? frame;

  /// 화면을 왼쪽으로 돌린 횟수.
  final int turns;
  final CropRect rect;
  final double? normRatio;
  final ValueChanged<CropRect> onChanged;

  @override
  State<CropCanvas> createState() => _CropCanvasState();
}

class _CropCanvasState extends State<CropCanvas> {
  /// 끌고 있는 모서리(0~3), -1 이면 상자 옮기기, null 이면 끌지 않음.
  int? _drag;

  int? _hit(Offset p, Size s) {
    final r = widget.rect;
    final corners = [
      Offset(r.left * s.width, r.top * s.height),
      Offset(r.right * s.width, r.top * s.height),
      Offset(r.right * s.width, r.bottom * s.height),
      Offset(r.left * s.width, r.bottom * s.height),
    ];
    for (var i = 0; i < 4; i++) {
      if ((corners[i] - p).distance < 32) return i;
    }
    final inside = Rect.fromLTRB(corners[0].dx, corners[0].dy, corners[2].dx, corners[2].dy);
    return inside.contains(p) ? -1 : null;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      final frame = widget.frame;
      return GestureDetector(
        onPanStart: (d) => _drag = _hit(d.localPosition, size),
        onPanUpdate: (d) {
          final drag = _drag;
          if (drag == null) return;
          final dx = d.delta.dx / size.width;
          final dy = d.delta.dy / size.height;
          widget.onChanged(
            drag < 0 ? widget.rect.move(dx, dy) : widget.rect.resize(drag, dx, dy, normRatio: widget.normRatio),
          );
        },
        onPanEnd: (_) => _drag = null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              if (frame != null)
                RotatedBox(
                  quarterTurns: (4 - widget.turns) % 4,
                  child: Image.memory(frame, fit: BoxFit.fill, gaplessPlayback: true),
                ),
              CustomPaint(painter: _CropPainter(widget.rect)),
            ],
          ),
        ),
      );
    },
  );
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.rect);

  final CropRect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
      rect.left * size.width,
      rect.top * size.height,
      rect.right * size.width,
      rect.bottom * size.height,
    );
    // 남지 않는 부분은 어둡게.
    final outside = Path()
      ..addRect(Offset.zero & size)
      ..addRect(r)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(outside, Paint()..color = const Color(0xA6000000));
    // 3등분 안내선.
    final guide = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = r.left + r.width * i / 3;
      final y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), guide);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), guide);
    }
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    // 모서리 손잡이.
    final handle = Paint()
      ..color = Palette.trim
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const l = 18.0;
    for (final (p, sx, sy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomRight, -1.0, -1.0),
      (r.bottomLeft, 1.0, -1.0),
    ]) {
      canvas.drawLine(p, p + Offset(l * sx, 0), handle);
      canvas.drawLine(p, p + Offset(0, l * sy), handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.rect != rect;
}
