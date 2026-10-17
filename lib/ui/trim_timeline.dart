import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/time_format.dart';
import 'theme.dart';

enum TimelineTarget { start, end, playhead }

/// 썸네일 띠 + 노란 구간 틀(양 끝 손잡이) + 흰 재생 위치 선.
///
/// 시작 시간 태그는 띠 위, 끝 시간 태그는 띠 아래에 두어 서로 겹치지 않는다.
/// 태그나 손잡이를 잡고 끌면 해당 지점이 움직이고, 탭하면 그 지점 화면을 보여준다.
/// 좌우 끝은 시스템 '뒤로 가기' 제스처 영역([edgePadding])만큼 비워 둔다.
class TrimTimeline extends StatefulWidget {
  const TrimTimeline({
    super.key,
    required this.durationUs,
    required this.startUs,
    required this.actualStartUs,
    required this.endUs,
    required this.playheadUs,
    required this.thumbnails,
    required this.keyframesUs,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
    this.stripHeight = 52,
    this.tickCount = 5,
    this.edgePadding = 0,
  });

  final int durationUs;
  final int startUs;
  final int actualStartUs;
  final int endUs;
  final int playheadUs;
  final List<Uint8List> thumbnails;
  final List<int> keyframesUs;
  final void Function(TimelineTarget target) onDragStart;
  final void Function(TimelineTarget target, int us) onDrag;
  final void Function(TimelineTarget target) onDragEnd;
  final double stripHeight;
  final int tickCount;
  final double edgePadding;

  static const handleWidth = 16.0;
  static const tagHeight = 28.0;
  static const tagWidth = 76.0;

  @override
  State<TrimTimeline> createState() => _TrimTimelineState();
}

class _TrimTimelineState extends State<TrimTimeline> {
  TimelineTarget? _active;
  double _grabOffset = 0;

  @override
  Widget build(BuildContext context) {
    const hw = TrimTimeline.handleWidth;
    const tagH = TrimTimeline.tagHeight;
    const tagW = TrimTimeline.tagWidth;
    const gap = 8.0;
    final h = widget.stripHeight;
    final pad = math.max(widget.edgePadding, hw);
    // 세로 배치: [시작 태그][간격][썸네일 띠][간격][끝 태그][눈금 시간]
    const stripTop = tagH + gap;
    final endTagTop = stripTop + h + gap;
    final ticksTop = endTagTop + tagH + 6;
    final totalH = ticksTop + 16;

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth - pad * 2;
        double x(int us) => pad + w * (us / widget.durationUs).clamp(0.0, 1.0);
        int usAt(double dx) => (((dx - pad) / w).clamp(0.0, 1.0) * widget.durationUs).round();
        final xs = x(widget.actualStartUs);
        final xe = x(widget.endUs);
        final xp = x(widget.playheadUs);
        double tagLeft(double cx) => (cx - tagW / 2).clamp(0.0, c.maxWidth - tagW);

        TimelineTarget pick(Offset p) {
          bool onTag(double cx) => p.dx >= tagLeft(cx) - 6 && p.dx <= tagLeft(cx) + tagW + 6;
          if (p.dy < stripTop) {
            return onTag(xs) ? TimelineTarget.start : TimelineTarget.playhead;
          }
          if (p.dy >= endTagTop) {
            return onTag(xe) ? TimelineTarget.end : TimelineTarget.playhead;
          }
          // 띠 위: 가까운 손잡이. 두 손잡이가 붙어 있으면 위쪽 절반은 시작, 아래쪽 절반은 끝.
          const reach = 26.0;
          final ds = (p.dx - (xs - hw / 2)).abs();
          final de = (p.dx - (xe + hw / 2)).abs();
          if (ds <= reach && de <= reach) {
            return p.dy < stripTop + h / 2 ? TimelineTarget.start : TimelineTarget.end;
          }
          if (ds <= reach) return TimelineTarget.start;
          if (de <= reach) return TimelineTarget.end;
          return TimelineTarget.playhead;
        }

        void begin(Offset p) {
          final t = pick(p);
          _active = t;
          _grabOffset = switch (t) {
            TimelineTarget.start => p.dx - x(widget.startUs),
            TimelineTarget.end => p.dx - xe,
            TimelineTarget.playhead => 0,
          };
          setState(() {});
          widget.onDragStart(t);
          if (t == TimelineTarget.playhead) widget.onDrag(t, usAt(p.dx));
        }

        void update(Offset p) {
          final t = _active;
          if (t != null) widget.onDrag(t, usAt(p.dx - _grabOffset));
        }

        void end() {
          final t = _active;
          _active = null;
          setState(() {});
          if (t != null) widget.onDragEnd(t);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => begin(d.localPosition),
          onHorizontalDragUpdate: (d) => update(d.localPosition),
          onHorizontalDragEnd: (_) => end(),
          onHorizontalDragCancel: () {
            if (_active != null) end();
          },
          onTapDown: (d) => begin(d.localPosition),
          onTapUp: (_) => end(),
          onTapCancel: () {},
          child: SizedBox(
            height: totalH,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 키프레임 눈금(띠 바로 위)
                if (widget.keyframesUs.isNotEmpty)
                  Positioned(
                    left: pad,
                    width: w,
                    top: stripTop - 7,
                    height: 4,
                    child: CustomPaint(painter: _KeyframePainter(widget.keyframesUs, widget.durationUs)),
                  ),
                // 썸네일 띠
                Positioned(
                  left: pad,
                  width: w,
                  top: stripTop,
                  height: h,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: widget.thumbnails.isEmpty
                        ? Container(color: Palette.s2)
                        : Row(
                            children: [
                              for (final t in widget.thumbnails)
                                Expanded(
                                  child: Image.memory(t, fit: BoxFit.cover, height: h, gaplessPlayback: true),
                                ),
                            ],
                          ),
                  ),
                ),
                // 잘려 나갈 부분 어둡게
                Positioned(
                  left: pad,
                  width: (xs - pad).clamp(0, w),
                  top: stripTop,
                  height: h,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Color(0xAD08090C),
                      borderRadius: BorderRadius.horizontal(left: Radius.circular(10)),
                    ),
                  ),
                ),
                Positioned(
                  left: xe,
                  right: pad,
                  top: stripTop,
                  height: h,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Color(0xAD08090C),
                      borderRadius: BorderRadius.horizontal(right: Radius.circular(10)),
                    ),
                  ),
                ),
                // 구간 틀 + 손잡이
                Positioned(
                  left: xs - hw,
                  width: xe - xs + hw * 2,
                  top: stripTop - 3,
                  height: h + 6,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: const Border.symmetric(
                          vertical: BorderSide(color: Palette.trim, width: hw),
                          horizontal: BorderSide(color: Palette.trim, width: 3),
                        ),
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                  ),
                ),
                _grip(xs - hw / 2, stripTop, h),
                _grip(xe + hw / 2, stripTop, h),
                // 재생 위치
                Positioned(
                  left: xp - 1.5,
                  top: stripTop - 6,
                  height: h + 12,
                  width: 3,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
                      ),
                    ),
                  ),
                ),
                // 시작 태그(위) / 끝 태그(아래)
                _tag(
                  left: tagLeft(xs),
                  top: 0,
                  pointerX: xs - tagLeft(xs),
                  pointDown: true,
                  label: '시작 ${formatTime(widget.startUs, decimals: 0)}',
                  active: _active == TimelineTarget.start,
                ),
                _tag(
                  left: tagLeft(xe),
                  top: endTagTop,
                  pointerX: xe - tagLeft(xe),
                  pointDown: false,
                  label: '끝 ${formatTime(widget.endUs, decimals: 0)}',
                  active: _active == TimelineTarget.end,
                ),
                // 아래 눈금 시간
                Positioned(
                  left: pad,
                  width: w,
                  top: ticksTop,
                  child: _Ticks(durationUs: widget.durationUs, count: widget.tickCount),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _grip(double cx, double top, double h) => Positioned(
    left: cx - 1.5,
    top: top + h / 2 - 8,
    width: 3,
    height: 16,
    child: IgnorePointer(
      child: Container(
        decoration: BoxDecoration(color: const Color(0xFF5A4300), borderRadius: BorderRadius.circular(2)),
      ),
    ),
  );

  Widget _tag({
    required double left,
    required double top,
    required double pointerX,
    required bool pointDown,
    required String label,
    required bool active,
  }) {
    const tagW = TrimTimeline.tagWidth;
    const tagH = TrimTimeline.tagHeight;
    final color = active ? Colors.white : Palette.trim;
    final arrowX = pointerX.clamp(10.0, tagW - 10.0);
    return Positioned(
      left: left,
      top: top,
      width: tagW,
      height: tagH,
      child: IgnorePointer(
        child: CustomPaint(
          painter: _TagPainter(color: color, arrowX: arrowX, pointDown: pointDown),
          child: Padding(
            padding: EdgeInsets.only(top: pointDown ? 0 : 5, bottom: pointDown ? 5 : 0),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF2B2100),
                    fontFeatures: tabular,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 둥근 사각형 + 손잡이를 가리키는 작은 삼각형.
class _TagPainter extends CustomPainter {
  _TagPainter({required this.color, required this.arrowX, required this.pointDown});

  final Color color;
  final double arrowX;
  final bool pointDown;

  @override
  void paint(Canvas canvas, Size size) {
    const arrow = 5.0;
    final paint = Paint()..color = color;
    final body = pointDown
        ? Rect.fromLTWH(0, 0, size.width, size.height - arrow)
        : Rect.fromLTWH(0, arrow, size.width, size.height - arrow);
    canvas.drawRRect(RRect.fromRectAndRadius(body, const Radius.circular(7)), paint);
    final path = Path();
    if (pointDown) {
      path
        ..moveTo(arrowX - arrow, body.bottom)
        ..lineTo(arrowX + arrow, body.bottom)
        ..lineTo(arrowX, size.height);
    } else {
      path
        ..moveTo(arrowX - arrow, body.top)
        ..lineTo(arrowX + arrow, body.top)
        ..lineTo(arrowX, 0);
    }
    canvas.drawPath(path..close(), paint);
  }

  @override
  bool shouldRepaint(_TagPainter old) => old.color != color || old.arrowX != arrowX || old.pointDown != pointDown;
}

class _Ticks extends StatelessWidget {
  const _Ticks({required this.durationUs, required this.count});

  final int durationUs;
  final int count;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      for (var i = 0; i < count; i++)
        Text(
          formatTick((durationUs * i / (count - 1)).round()),
          style: const TextStyle(fontSize: 10.5, color: Palette.dim, fontFeatures: tabular),
        ),
    ],
  );
}

class _KeyframePainter extends CustomPainter {
  _KeyframePainter(this.keyframes, this.duration);

  final List<int> keyframes;
  final int duration;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFF6E7480)
      ..strokeWidth = 2;
    var lastX = -10.0;
    for (final k in keyframes) {
      final x = size.width * k / duration;
      // 너무 촘촘하면 3px 간격으로 솎아낸다.
      if (x - lastX < 3) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      lastX = x;
    }
  }

  @override
  bool shouldRepaint(_KeyframePainter old) => old.keyframes != keyframes || old.duration != duration;
}
