/// 시간 표시·입력 변환. 내부 시간 단위는 전부 마이크로초(us)다.
library;

const int usPerSecond = 1000000;

/// `mm:ss.s` (1시간 이상이면 `h:mm:ss.s`). [decimals]가 0이면 소수점 없이.
String formatTime(int us, {int decimals = 1}) {
  if (us < 0) us = 0;
  final unit = decimals == 0 ? usPerSecond : usPerSecond ~/ _pow10(decimals);
  // 표시 단위로 내림해서 01:12.39 가 01:12.4 로 올라가 보이지 않게 한다.
  final ticks = us ~/ unit;
  final perSecond = usPerSecond ~/ unit;
  final totalSeconds = ticks ~/ perSecond;
  final frac = ticks % perSecond;
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  final buf = StringBuffer();
  if (h > 0) {
    buf.write('$h:${m.toString().padLeft(2, '0')}');
  } else {
    buf.write(m.toString().padLeft(2, '0'));
  }
  buf.write(':${s.toString().padLeft(2, '0')}');
  if (decimals > 0) buf.write('.${frac.toString().padLeft(decimals, '0')}');
  return buf.toString();
}

/// 타임라인 눈금용 짧은 표기: `0:51`, `1:02:03`.
String formatTick(int us) {
  final total = us ~/ usPerSecond;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// 사용자가 입력한 시간을 해석한다. 실패하면 null.
///
/// 허용: `72`, `72.4`, `1:12`, `1:12.4`, `01:12.40`, `1:02:03.5`.
int? parseTime(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final parts = text.split(':');
  if (parts.length > 3) return null;
  final secPart = parts.last;
  if (!RegExp(r'^\d+(\.\d{0,6})?$').hasMatch(secPart)) return null;
  for (final p in parts.take(parts.length - 1)) {
    if (!RegExp(r'^\d+$').hasMatch(p)) return null;
  }
  final dot = secPart.indexOf('.');
  final whole = int.parse(dot < 0 ? secPart : secPart.substring(0, dot));
  var fracUs = 0;
  if (dot >= 0) {
    final digits = secPart.substring(dot + 1).padRight(6, '0');
    fracUs = int.parse(digits);
  }
  var minutes = 0;
  var hours = 0;
  if (parts.length >= 2) {
    minutes = int.parse(parts[parts.length - 2]);
    // 분·초가 함께 있으면 초는 60 미만이어야 한다.
    if (whole >= 60) return null;
  }
  if (parts.length == 3) {
    hours = int.parse(parts[0]);
    if (minutes >= 60) return null;
  }
  return ((hours * 3600 + minutes * 60 + whole) * usPerSecond) + fracUs;
}

/// 바이트를 `72 MB`, `1.2 GB` 처럼.
String formatBytes(int bytes) {
  const mb = 1024 * 1024;
  const gb = 1024 * mb;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= 100 * mb) return '${(bytes / mb).round()} MB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).ceil()} KB';
}

int _pow10(int n) {
  var r = 1;
  for (var i = 0; i < n; i++) {
    r *= 10;
  }
  return r;
}
