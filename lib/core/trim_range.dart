/// 자르기 구간 규칙: 0 ≤ start, end ≤ duration, end - start ≥ [minGapUs].
library;

const int minGapUs = 1000000;

class TrimRange {
  const TrimRange(this.startUs, this.endUs);

  final int startUs;
  final int endUs;

  int get lengthUs => endUs - startUs;

  @override
  bool operator ==(Object other) => other is TrimRange && other.startUs == startUs && other.endUs == endUs;

  @override
  int get hashCode => Object.hash(startUs, endUs);

  @override
  String toString() => 'TrimRange($startUs, $endUs)';
}

/// 1초 이상 남길 수 있는 영상인지.
bool canTrim(int durationUs) => durationUs >= minGapUs;

/// 시작점을 [value]로 옮긴다. 끝과의 간격이 1초 미만이 되면 끝 - 1초에서 멈춘다.
TrimRange moveStart(TrimRange r, int value) {
  final s = value.clamp(0, r.endUs - minGapUs);
  return TrimRange(s, r.endUs);
}

/// 끝점을 [value]로 옮긴다. 시작과의 간격이 1초 미만이 되면 시작 + 1초에서 멈춘다.
TrimRange moveEnd(TrimRange r, int value, int durationUs) {
  final e = value.clamp(r.startUs + minGapUs, durationUs);
  return TrimRange(r.startUs, e);
}

/// [t] 이하에서 가장 가까운 키프레임. 키프레임 정보가 없으면 [t] 그대로.
/// 키프레임 정보가 깨져 자르기가 안 될 파일인지.
///
/// 키프레임이 하나도 없거나(자를 시작점을 못 찾는다), 거의 모든 프레임이 키프레임으로 적혀 있으면
/// (스트리밍을 옮긴 파일에서 생긴다. 아무 프레임에서나 잘라 앞부분이 깨진다) 고쳐서 써야 한다.
bool needsRepair({required List<int> keyframesUs, required int durationUs, required double fps}) {
  if (keyframesUs.isEmpty) return true;
  final frames = durationUs / 1e6 * (fps > 0 ? fps : 30);
  return frames >= 30 && keyframesUs.length >= frames * 0.9;
}

int keyframeAtOrBefore(List<int> keyframes, int t) {
  if (keyframes.isEmpty) return t;
  var lo = 0;
  var hi = keyframes.length - 1;
  if (t < keyframes[0]) return keyframes[0];
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (keyframes[mid] <= t) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return keyframes[lo];
}

/// [t]보다 앞의 키프레임(없으면 null).
int? previousKeyframe(List<int> keyframes, int t) {
  int? found;
  for (final k in keyframes) {
    if (k < t) {
      found = k;
    } else {
      break;
    }
  }
  return found;
}

/// [t]보다 뒤의 키프레임(없으면 null).
int? nextKeyframe(List<int> keyframes, int t) {
  for (final k in keyframes) {
    if (k > t) return k;
  }
  return null;
}

/// 시작·끝은 초 단위로만 고른다. 가장 가까운 초로 반올림하되, 영상 끝 0.5초 안쪽은 영상 끝 그대로.
int snapToSecond(int us, int durationUs) {
  if (us >= durationUs - usPerSecondHalf) return durationUs;
  if (us <= 0) return 0;
  return ((us + usPerSecondHalf) ~/ 1000000) * 1000000;
}

const int usPerSecondHalf = 500000;

int _floorSecond(int us) => (us ~/ 1000000) * 1000000;

/// 초 단위 시작 이동: 반올림 후, 끝보다 최소 1초 앞의 '정수 초'까지만.
TrimRange moveStartSec(TrimRange r, int value, int durationUs) {
  final limit = _floorSecond(r.endUs - minGapUs);
  final s = snapToSecond(value, durationUs).clamp(0, limit < 0 ? 0 : limit);
  return TrimRange(s, r.endUs);
}

/// 초 단위 끝 이동: 반올림(영상 끝 근처는 영상 끝) 후, 시작보다 최소 1초 뒤부터.
TrimRange moveEndSec(TrimRange r, int value, int durationUs) {
  final low = r.startUs + minGapUs;
  final e = snapToSecond(value, durationUs).clamp(low > durationUs ? durationUs : low, durationUs);
  return TrimRange(r.startUs, e);
}
