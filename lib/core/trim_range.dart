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
