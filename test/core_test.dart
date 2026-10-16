import 'package:flutter_test/flutter_test.dart';
import 'package:zamzam/core/time_format.dart';
import 'package:zamzam/core/trim_range.dart';
import 'package:zamzam/core/video_info.dart';

VideoInfo _video({
  int width = 1920,
  int height = 1080,
  int rotation = 0,
  String mime = 'video/hevc',
  String? sig = 'abc',
  String? audio = 'audio/mp4a-latm',
  int rate = 48000,
}) => VideoInfo(
  uri: 'u',
  name: 'n.mp4',
  sizeBytes: 1,
  durationUs: 1,
  width: width,
  height: height,
  rotation: rotation,
  videoMime: mime,
  videoSignature: sig,
  fps: 30,
  audioMime: audio,
  audioSampleRate: audio == null ? null : rate,
  audioChannels: audio == null ? null : 2,
  keyframesUs: const [],
  exactCut: false,
);

void main() {
  group('formatTime', () {
    test('minutes and tenths', () {
      expect(formatTime(72400000), '01:12.4');
      expect(formatTime(204000000), '03:24.0');
      expect(formatTime(0), '00:00.0');
    });
    test('rounds down so the display never runs ahead', () {
      expect(formatTime(72399999), '01:12.3');
    });
    test('hours and no decimals', () {
      expect(formatTime(3723500000), '1:02:03.5');
      expect(formatTime(108900000, decimals: 0), '01:48');
    });
  });

  group('parseTime', () {
    test('accepts common forms', () {
      expect(parseTime('72'), 72000000);
      expect(parseTime('72.4'), 72400000);
      expect(parseTime('1:12'), 72000000);
      expect(parseTime('01:12.4'), 72400000);
      expect(parseTime(' 1:12.45 '), 72450000);
      expect(parseTime('1:02:03.5'), 3723500000);
    });
    test('round-trips formatted values', () {
      for (final us in [0, 100000, 72400000, 3723500000]) {
        expect(parseTime(formatTime(us)), us);
      }
    });
    test('rejects junk', () {
      for (final s in ['', 'abc', '1:75', '1:2:3:4', '1.2.3', ':12', '1:60:00', '-3']) {
        expect(parseTime(s), isNull, reason: s);
      }
    });
  });

  group('trim range rules', () {
    const dur = 204000000;
    const full = TrimRange(0, dur);
    test('start stops one second before end', () {
      final r = moveStart(const TrimRange(0, 10000000), 9800000);
      expect(r, const TrimRange(9000000, 10000000));
    });
    test('end stops one second after start', () {
      final r = moveEnd(const TrimRange(5000000, dur), 5200000, dur);
      expect(r, const TrimRange(5000000, 6000000));
    });
    test('clamped to the video', () {
      expect(moveStart(full, -5), full);
      expect(moveEnd(full, dur + 99, dur), full);
    });
    test('needs at least one second of video', () {
      expect(canTrim(999999), isFalse);
      expect(canTrim(1000000), isTrue);
    });
  });

  group('keyframes', () {
    const kfs = [0, 2000000, 4000000, 6000000];
    test('snaps start back to the previous keyframe', () {
      expect(keyframeAtOrBefore(kfs, 3999999), 2000000);
      expect(keyframeAtOrBefore(kfs, 4000000), 4000000);
      expect(keyframeAtOrBefore(kfs, 99000000), 6000000);
      expect(keyframeAtOrBefore(const [], 1234), 1234);
    });
    test('previous / next', () {
      expect(previousKeyframe(kfs, 4000000), 2000000);
      expect(previousKeyframe(kfs, 0), isNull);
      expect(nextKeyframe(kfs, 4000000), 6000000);
      expect(nextKeyframe(kfs, 6000000), isNull);
    });
  });

  group('merge compatibility', () {
    test('same format passes', () {
      expect(incompatibilityReasons(_video(), _video()), isEmpty);
    });
    test('portrait vs landscape', () {
      expect(incompatibilityReasons(_video(), _video(rotation: 90)), ['세로 영상이에요']);
      expect(incompatibilityReasons(_video(), _video(width: 1080, height: 1920)), ['세로 영상이에요']);
    });
    test('resolution, codec, encoder settings, audio', () {
      expect(incompatibilityReasons(_video(), _video(width: 3840, height: 2160)).single, contains('해상도'));
      expect(incompatibilityReasons(_video(), _video(mime: 'video/avc')).first, contains('코덱'));
      expect(incompatibilityReasons(_video(), _video(sig: 'zzz')), ['인코딩 설정이 달라요']);
      expect(incompatibilityReasons(_video(), _video(sig: null)), isEmpty);
      expect(incompatibilityReasons(_video(), _video(audio: null)), ['소리가 없는 영상이에요']);
      expect(incompatibilityReasons(_video(), _video(rate: 44100)).single, contains('오디오'));
    });
  });

  group('estimateBytes', () {
    VideoInfo dense({List<int> kfs = const [0, 10000000, 20000000], List<int> cum = const [0, 1000, 9000]}) =>
        VideoInfo(
          uri: 'u',
          name: 'n',
          sizeBytes: 10000,
          durationUs: 30000000,
          width: 1,
          height: 1,
          rotation: 0,
          videoMime: 'video/avc',
          videoSignature: null,
          fps: 30,
          audioMime: null,
          audioSampleRate: null,
          audioChannels: null,
          keyframesUs: kfs,
          exactCut: false,
          keyframeBytes: cum,
          videoBytes: 10000,
          audioBytes: 300,
        );
    test('follows the real bitrate of the range', () {
      // 0~10s 1000B, 10~20s 8000B, 20~30s 1000B, 음성 300B 균등
      expect(estimateBytes(dense(), 0, 10000000), 1000 + 100);
      expect(estimateBytes(dense(), 10000000, 20000000), 8000 + 100);
      expect(estimateBytes(dense(), 15000000, 25000000), 4000 + 500 + 100);
    });
    test('falls back to the length ratio without sample data', () {
      expect(estimateBytes(_video(), 0, 1), 1);
      expect(estimateBytes(dense(cum: const []), 0, 15000000), 5000);
    });
    test('flags a transcoded copy', () {
      expect(dense().looksTranscoded, isFalse);
      final big = VideoInfo.fromMap({
        'uri': 'u',
        'durationUs': 1,
        'width': 1,
        'height': 1,
        'videoMime': 'video/avc',
        'size': 1000,
        'videoBytes': 3000,
      });
      expect(big.looksTranscoded, isTrue);
    });
  });

  test('formatBytes', () {
    expect(formatBytes(72 * 1024 * 1024), '72.0 MB');
    expect(formatBytes(382 * 1024 * 1024), '382 MB');
    expect(formatBytes(2 * 1024 * 1024 * 1024), '2.00 GB');
  });
}
