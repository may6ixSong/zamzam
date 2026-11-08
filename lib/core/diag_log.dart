/// 문제 진단용 기록: 자르기 화면에서 일어난 일(단계, 걸린 시간, 오류)을 최근 것만 남긴다.
abstract final class DiagLog {
  static final _lines = <String>[];
  static const _max = 80;

  static void add(String message) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    _lines.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)} $message');
    if (_lines.length > _max) _lines.removeRange(0, _lines.length - _max);
  }

  static List<String> get lines => List.unmodifiable(_lines);
}
