/// 다운로드 화질 고르기: 사이트가 준비한 화질(HLS) 또는 받은 뒤 해상도 낮추기(재인코딩).
library;

/// 해상도 낮추기 목표(짧은 변 기준).
const reencodeTargets = [1080, 720, 480, 360];

/// 짧은 변 기준 목표 영상 비트레이트(bps). 네이티브 Transcoder 와 같은 값.
const _targetBitrate = {1080: 5000000, 720: 2500000, 480: 1200000, 360: 700000};

/// 음성은 그대로 옮기므로 대략 이 정도로 본다.
const _audioBitrate = 128000;

class QualityOption {
  const QualityOption({
    required this.label,
    this.sizeBytes,
    this.estimated = false,
    this.variantUrl,
    this.maxShortSide,
  });

  /// 예: "1080p", "원본".
  final String label;

  /// 예상(또는 정확한) 용량. 모르면 null.
  final int? sizeBytes;
  final bool estimated;

  /// HLS 화질 주소. 이 화질을 그대로 받는다(화질 손실 없음).
  final String? variantUrl;

  /// 받은 뒤 이 해상도로 낮춰 다시 압축한다(시간이 걸린다).
  final int? maxShortSide;

  bool get reencode => maxShortSide != null;
}

/// 사이트가 준비한 화질 하나.
class StreamVariant {
  const StreamVariant({required this.url, required this.width, required this.height, required this.bandwidth});

  final String url;
  final int width;
  final int height;
  final int bandwidth;

  int get shortSide => width > 0 && height > 0 ? (width < height ? width : height) : 0;
}

/// 받기 전에 알아본 영상 정보(네이티브 inspectVideo 결과).
class VideoInspection {
  const VideoInspection({required this.isHls, this.sizeBytes, this.durationSec = 0, this.variants = const []});

  final bool isHls;
  final int? sizeBytes;
  final double durationSec;
  final List<StreamVariant> variants;

  factory VideoInspection.fromMap(Map<dynamic, dynamic> m) => VideoInspection(
    isHls: m['kind'] == 'hls',
    sizeBytes: (m['sizeBytes'] as num?)?.toInt(),
    durationSec: (m['durationSec'] as num?)?.toDouble() ?? 0,
    variants: [
      for (final v in (m['variants'] as List? ?? const []))
        if (v is Map && v['url'] is String)
          StreamVariant(
            url: v['url'] as String,
            width: (v['width'] as num?)?.toInt() ?? 0,
            height: (v['height'] as num?)?.toInt() ?? 0,
            bandwidth: (v['bandwidth'] as num?)?.toInt() ?? 0,
          ),
    ],
  );
}

/// 고를 수 있는 화질 목록(좋은 화질 먼저). 첫 항목이 기본값.
///
/// [width]·[height]는 페이지에서 재생 중인 원본 해상도(모르면 0), [durationSec]는 길이(모르면 0).
List<QualityOption> qualityOptions(
  VideoInspection info, {
  int width = 0,
  int height = 0,
  double durationSec = 0,
  bool canReencode = true,
}) {
  final dur = info.durationSec > 0 ? info.durationSec : durationSec;
  int? bytesFor(int bps) => dur > 0 && bps > 0 ? (bps * dur / 8).round() : null;

  // 사이트가 여러 화질을 준비해 둔 스트리밍: 그대로 고른다.
  if (info.isHls && info.variants.isNotEmpty) {
    var i = 0;
    return [
      for (final v in info.variants)
        QualityOption(
          label: v.shortSide > 0 ? '${v.shortSide}p' : '화질 ${++i}',
          sizeBytes: bytesFor(v.bandwidth),
          estimated: true,
          variantUrl: v.url,
        ),
    ];
  }

  final options = <QualityOption>[QualityOption(label: '원본', sizeBytes: info.sizeBytes)];
  if (!canReencode) return options;
  final srcShort = width > 0 && height > 0 ? (width < height ? width : height) : 0;
  // 원본 영상 비트레이트(용량과 길이를 알 때). 이보다 크게 만들지 않는다.
  final srcBps = info.sizeBytes != null && dur > 0 ? info.sizeBytes! * 8 / dur - _audioBitrate : null;
  for (final t in reencodeTargets) {
    if (srcShort > 0 && t >= srcShort) continue;
    if (srcShort == 0 && t > 720) continue;
    var bps = _targetBitrate[t]!.toDouble();
    if (srcBps != null && srcShort > 0) {
      final scale = t / srcShort;
      final capped = srcBps * scale * scale * 1.1;
      if (capped < bps) bps = capped < 300000 ? 300000 : capped;
    }
    options.add(
      QualityOption(
        label: '${t}p',
        sizeBytes: bytesFor((bps + _audioBitrate).round()),
        estimated: true,
        maxShortSide: t,
      ),
    );
  }
  return options;
}
