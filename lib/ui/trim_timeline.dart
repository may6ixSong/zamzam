import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/time_format.dart';
import 'theme.dart';

enum TimelineTarget { start, end, playhead }

/// 썸네일 띠 + 노란 구간 틀(양 끝 손잡이) + 흰 재생 위치 선.
///
/// 손잡이는 띠 바깥으로 [handleWidth]만큼 나오므로 좌우에 그만큼 여백을 둔다.
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

  static const handleWidth = 16.0;

  @override
  State<TrimTimeline> createState() => _TrimTimelineState();
}

class _TrimTimelineState extends State<TrimTimeline> {
  TimelineTarget? _active;
  double _grabOffset = 0;

  @override
  Widget build(BuildContext context) {
    const hw = TrimTimeline.handleWidth;
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth - hw * 2;
        double x(int us) => hw + w * (us / widget.durationUs).clamp(0.0, 1.0);
        int usAt(double dx) => (((dx - hw) / w).clamp(0.0, 1.0) * widget.durationUs).round();
        final xs = x(widget.actualStartUs);
        final xe = x(widget.endUs);
        final xp = x(widget.playheadUs);
        final h = widget.stripHeight;
        const flagH = 30.0;

        TimelineTarget pick(double dx) {
          // 손잡이 근처를 잡으면 손잡이, 아니면 재생 위치.
          final ds = (dx - (xs - hw / 2)).abs();
          final de = (dx - (xe + hw / 2)).abs();
          const reach = 28.0;
          if (ds <= reach || de <= reach) return ds <= de ? TimelineTarget.start : TimelineTarget.end;
          return TimelineTarget.playhead;
        }

        void begin(double dx) {
          final t = pick(dx);
          _active = t;
          _grabOffset = switch (t) {
            TimelineTarget.start => dx - x(widget.startUs),
            TimelineTarget.end => dx - xe,
            TimelineTarget.playhead => 0,
          };
          widget.onDragStart(t);
          if (t == TimelineTarget.playhead) widget.onDrag(t, usAt(dx));
        }

        void update(double dx) {
          final t = _active;
          if (t != null) widget.onDrag(t, usAt(dx - _grabOffset));
        }

        void end() {
          final t = _active;
          _active = null;
          if (t != null) widget.onDragEnd(t);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => begin(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => update(d.localPosition.dx),
          onHorizontalDragEnd: (_) => end(),
          onHorizontalDragCancel: end,
          onTapDown: (d) => begin(d.localPosition.dx),
          onTapUp: (_) => end(),
          child: SizedBox(
            height: flagH + h + 32,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 키프레임 눈금
                if (widget.keyframesUs.isNotEmpty)
                  Positioned(
                    left: hw,
                    width: w,
                    top: flagH - 8,
                    height: 5,
                    child: CustomPaint(painter: _KeyframePainter(widget.keyframesUs, widget.durationUs)),
                  ),
                // 썸네일 띠
                Positioned(
                  left: hw,
                  width: w,
                  top: flagH,
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
                  left: hw,
                  width: (xs - hw).clamp(0, w),
                  top: flagH,
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
                  right: hw,
                  top: flagH,
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
                  top: flagH - 3,
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
                _grip(xs - hw / 2, flagH, h),
                _grip(xe + hw / 2, flagH, h),
                // 시간 깃발
                _flag(xs, widget.actualStartUs, c.maxWidth, highlight: _active == TimelineTarget.start),
                _flag(xe, widget.endUs, c.maxWidth, highlight: _active == TimelineTarget.end),
                // 재생 위치
                Positioned(
                  left: xp - 1.5,
                  top: flagH - 9,
                  height: h + 18,
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
                Positioned(
                  left: xp - 6,
                  top: flagH - 11,
                  child: IgnorePointer(
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    ),
                  ),
                ),
                // 아래 눈금 시간
                Positioned(
                  left: hw,
                  width: w,
                  top: flagH + h + 12,
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

  Widget _flag(double cx, int us, double maxW, {required bool highlight}) {
    const fw = 64.0;
    final left = (cx - fw / 2).clamp(0.0, maxW - fw);
    return Positioned(
      left: left,
      top: 0,
      width: fw,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: highlight ? Colors.white : Palette.trim,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              formatTime(us),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2B2100),
                fontFeatures: tabular,
              ),
            ),
          ),
        ),
      ),
    );
  }
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
