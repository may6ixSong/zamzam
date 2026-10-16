/// 네이티브 엔진이 돌려주는 원본 영상 정보.
class VideoInfo {
  const VideoInfo({
    required this.uri,
    required this.name,
    required this.sizeBytes,
    required this.durationUs,
    required this.width,
    required this.height,
    required this.rotation,
    required this.videoMime,
    required this.videoSignature,
    required this.fps,
    required this.audioMime,
    required this.audioSampleRate,
    required this.audioChannels,
    required this.keyframesUs,
    required this.exactCut,
  });

  /// Android 는 content:// URI, iOS 는 앱 임시 폴더의 파일 경로.
  final String uri;
  final String name;
  final int sizeBytes;
  final int durationUs;

  /// 저장된(회전 전) 프레임 크기.
  final int width;
  final int height;
  final int rotation;
  final String videoMime;

  /// 코덱 설정(SPS/PPS 등) 지문. 다르면 무손실로 이어붙일 수 없다. 플랫폼이 판별하지 못하면 null.
  final String? videoSignature;
  final double fps;
  final String? audioMime;
  final int? audioSampleRate;
  final int? audioChannels;

  /// 오름차순 키프레임 시각. 비어 있으면 키프레임 정보 없음.
  final List<int> keyframesUs;

  /// true 면 시작점을 키프레임에 맞추지 않아도 정확히 잘린다(iOS).
  final bool exactCut;

  bool get hasAudio => audioMime != null;
  bool get isPortrait => rotation % 180 != 0 ? width > height : height > width;
  int get displayWidth => rotation % 180 != 0 ? height : width;
  int get displayHeight => rotation % 180 != 0 ? width : height;

  String get codecLabel => switch (videoMime) {
    'video/hevc' => 'HEVC',
    'video/avc' => 'H.264',
    'video/av01' => 'AV1',
    'video/x-vnd.on2.vp9' => 'VP9',
    _ => videoMime.replaceFirst('video/', '').toUpperCase(),
  };

  String get audioLabel {
    if (audioMime == null) return '소리 없음';
    final codec = switch (audioMime) {
      'audio/mp4a-latm' => 'AAC',
      'audio/opus' => 'Opus',
      'audio/ac3' => 'AC-3',
      'audio/eac3' => 'E-AC-3',
      _ => audioMime!.replaceFirst('audio/', '').toUpperCase(),
    };
    final khz = audioSampleRate == null
        ? ''
        : ' ${(audioSampleRate! / 1000).toStringAsFixed(audioSampleRate! % 1000 == 0 ? 0 : 1)}kHz';
    return '$codec$khz';
  }

  String get resolutionLabel => '$displayWidth×$displayHeight';
  String get fpsLabel => '${fps.round()}fps';

  factory VideoInfo.fromMap(Map<dynamic, dynamic> m) => VideoInfo(
    uri: m['uri'] as String,
    name: m['name'] as String? ?? 'video',
    sizeBytes: (m['size'] as num?)?.toInt() ?? 0,
    durationUs: (m['durationUs'] as num).toInt(),
    width: (m['width'] as num).toInt(),
    height: (m['height'] as num).toInt(),
    rotation: (m['rotation'] as num?)?.toInt() ?? 0,
    videoMime: m['videoMime'] as String,
    videoSignature: m['videoSig'] as String?,
    fps: (m['fps'] as num?)?.toDouble() ?? 30,
    audioMime: m['audioMime'] as String?,
    audioSampleRate: (m['sampleRate'] as num?)?.toInt(),
    audioChannels: (m['channels'] as num?)?.toInt(),
    keyframesUs: [for (final k in (m['keyframesUs'] as List?) ?? const []) (k as num).toInt()],
    exactCut: m['exactCut'] as bool? ?? false,
  );
}

/// 무손실 이어붙이기가 가능한지 [base] 기준으로 판정하고, 안 되면 사람이 읽을 이유를 돌려준다.
List<String> incompatibilityReasons(VideoInfo base, VideoInfo other) {
  final reasons = <String>[];
  if (base.videoMime != other.videoMime) {
    reasons.add('코덱이 달라요 (${other.codecLabel})');
  }
  if (base.isPortrait != other.isPortrait) {
    reasons.add(other.isPortrait ? '세로 영상이에요' : '가로 영상이에요');
  } else if (base.displayWidth != other.displayWidth || base.displayHeight != other.displayHeight) {
    reasons.add('해상도가 달라요 (${other.resolutionLabel})');
  } else if (base.rotation != other.rotation) {
    reasons.add('화면 방향이 달라요');
  }
  if (reasons.isEmpty &&
      base.videoSignature != null &&
      other.videoSignature != null &&
      base.videoSignature != other.videoSignature) {
    reasons.add('인코딩 설정이 달라요');
  }
  if (base.hasAudio != other.hasAudio) {
    reasons.add(other.hasAudio ? '소리가 있는 영상이에요' : '소리가 없는 영상이에요');
  } else if (base.hasAudio &&
      (base.audioMime != other.audioMime ||
          base.audioSampleRate != other.audioSampleRate ||
          base.audioChannels != other.audioChannels)) {
    reasons.add('오디오 형식이 달라요 (${other.audioLabel})');
  }
  return reasons;
}
