/// 크기 자르기: 남길 영역(0~1, 왼쪽 위 기준)과 비율 맞추기·끌기·크기 바꾸기 계산.
library;

import 'dart:math' as math;

/// 영역 비율 고르기. [ratio]는 가로/세로(픽셀 기준), null 이면 자유, [original]이면 화면 그대로.
enum CropAspect {
  free('자유', null),
  original('원본', null),
  square('1:1', 1),
  portrait('9:16', 9 / 16),
  landscape('16:9', 16 / 9),
  insta('4:5', 4 / 5);

  const CropAspect(this.label, this.ratio);

  final String label;
  final double? ratio;
}

/// 남길 영역. 값은 화면(회전 반영) 가로·세로에 대한 비율 0~1.
class CropRect {
  const CropRect(this.left, this.top, this.right, this.bottom);

  static const full = CropRect(0, 0, 1, 1);

  /// 영역의 최소 크기(비율).
  static const minSize = 0.1;

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get area => width * height;
  bool get isFull => left <= 0.001 && top <= 0.001 && right >= 0.999 && bottom >= 0.999;

  List<double> toList() => [left, top, right, bottom];

  /// 화면 비율 [frameAspect](가로/세로)에서 픽셀 비율 [ratio]를 만족하는 가장 큰 가운데 영역.
  static CropRect fit(double ratio, double frameAspect) {
    final r = ratio / frameAspect;
    final w = r <= 1 ? r : 1.0;
    final h = r <= 1 ? 1.0 : 1 / r;
    return CropRect((1 - w) / 2, (1 - h) / 2, (1 + w) / 2, (1 + h) / 2);
  }

  /// 크기는 그대로 두고 [dx],[dy]만큼 옮긴다(화면 밖으로 나가지 않게).
  CropRect move(double dx, double dy) {
    final nx = (left + dx).clamp(0.0, 1 - width);
    final ny = (top + dy).clamp(0.0, 1 - height);
    return CropRect(nx, ny, nx + width, ny + height);
  }

  /// 모서리 하나를 끌어 크기를 바꾼다. [corner]: 0 왼위, 1 오른위, 2 오른아래, 3 왼아래.
  /// [normRatio]가 있으면(= 픽셀 비율 / 화면 비율) 그 비율을 유지하고, 반대 모서리는 고정한다.
  CropRect resize(int corner, double dx, double dy, {double? normRatio}) {
    final fixX = (corner == 0 || corner == 3) ? right : left;
    final fixY = (corner == 0 || corner == 1) ? bottom : top;
    final leftSide = corner == 0 || corner == 3;
    final topSide = corner == 0 || corner == 1;
    // 끄는 모서리는 반대 모서리를 넘지 못하고, 최소 크기에서 멈춘다.
    var mx = (leftSide ? left : right) + dx;
    var my = (topSide ? top : bottom) + dy;
    mx = leftSide ? mx.clamp(0.0, fixX - minSize) : mx.clamp(fixX + minSize, 1.0);
    my = topSide ? my.clamp(0.0, fixY - minSize) : my.clamp(fixY + minSize, 1.0);
    var w = (mx - fixX).abs();
    var h = (my - fixY).abs();
    if (normRatio != null) {
      // 더 많이 움직인 쪽을 따르고, 화면 안에 들어가도록 줄인다.
      if (w / h > normRatio) {
        h = w / normRatio;
      } else {
        w = h * normRatio;
      }
      final maxW = (corner == 0 || corner == 3) ? fixX : 1 - fixX;
      final maxH = (corner == 0 || corner == 1) ? fixY : 1 - fixY;
      final s = math.min(1.0, math.min(maxW / w, maxH / h));
      w *= s;
      h *= s;
    } else {
      w = math.min(w, (corner == 0 || corner == 3) ? fixX : 1 - fixX);
      h = math.min(h, (corner == 0 || corner == 1) ? fixY : 1 - fixY);
    }
    final l = (corner == 0 || corner == 3) ? fixX - w : fixX;
    final t = (corner == 0 || corner == 1) ? fixY - h : fixY;
    return CropRect(l, t, l + w, t + h);
  }
}

/// 짝수로 맞춘 결과 크기(픽셀). [width]·[height]는 회전까지 반영한 화면 크기.
(int, int) cropOutputSize(int width, int height, CropRect r) {
  int even(double v) => math.max(2, (v / 2).round() * 2);
  return (even(width * r.width), even(height * r.height));
}

/// 예상 용량: 영상 데이터는 남는 면적만큼(조금 여유), 원본보다 크지 않게. 음성은 그대로.
int estimateCropBytes({required int videoBytes, required int audioBytes, required CropRect rect}) {
  final video = math.min(videoBytes.toDouble(), videoBytes * rect.area * 1.1);
  return (video + audioBytes).round();
}
