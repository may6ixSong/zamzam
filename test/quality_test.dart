import 'package:flutter_test/flutter_test.dart';
import 'package:zamzam/core/quality.dart';

void main() {
  test('스트리밍: 사이트가 준비한 화질을 그대로 보여 주고 용량을 예상한다', () {
    final info = VideoInspection.fromMap({
      'kind': 'hls',
      'durationSec': 100.0,
      'variants': [
        {'url': 'https://a/1080.m3u8', 'width': 1920, 'height': 1080, 'bandwidth': 4000000},
        {'url': 'https://a/480.m3u8', 'width': 854, 'height': 480, 'bandwidth': 800000},
      ],
    });
    final o = qualityOptions(info);
    expect(o.map((e) => e.label), ['1080p', '480p']);
    expect(o.first.sizeBytes, 50000000); // 4Mbps × 100초 / 8
    expect(o.last.variantUrl, 'https://a/480.m3u8');
    expect(o.any((e) => e.reencode), isFalse);
  });

  test('세로 영상은 짧은 변으로 표시', () {
    final info = VideoInspection.fromMap({
      'kind': 'hls',
      'variants': [
        {'url': 'u', 'width': 720, 'height': 1280, 'bandwidth': 1},
      ],
    });
    expect(qualityOptions(info).single.label, '720p');
  });

  test('파일: 원본 + 원본보다 낮은 해상도 변환', () {
    final info = VideoInspection.fromMap({'kind': 'file', 'sizeBytes': 100000000});
    final o = qualityOptions(info, width: 1280, height: 720, durationSec: 100);
    expect(o.map((e) => e.label), ['원본', '480p', '360p']);
    expect(o.first.sizeBytes, 100000000);
    expect(o.first.reencode, isFalse);
    expect(o[1].maxShortSide, 480);
    // 변환 결과는 원본보다 작게 예상돼야 한다.
    for (final e in o.skip(1)) {
      expect(e.sizeBytes, lessThan(100000000));
    }
  });

  test('원본 비트레이트가 낮으면 그 비율로만 줄인다(괜히 커지지 않게)', () {
    // 720p 인데 10MB/100초 = 0.8Mbps(음성 포함)
    final info = VideoInspection.fromMap({'kind': 'file', 'sizeBytes': 10000000});
    final o = qualityOptions(info, width: 1280, height: 720, durationSec: 100);
    final p480 = o.firstWhere((e) => e.label == '480p');
    expect(p480.sizeBytes, lessThan(10000000));
  });

  test('해상도를 모르면 720p 이하만, 길이를 모르면 용량은 null', () {
    final o = qualityOptions(const VideoInspection(isHls: false));
    expect(o.map((e) => e.label), ['원본', '720p', '480p', '360p']);
    expect(o[1].sizeBytes, isNull);
  });

  test('iOS 처럼 변환을 못 하면 원본만', () {
    final o = qualityOptions(
      const VideoInspection(isHls: false, sizeBytes: 5),
      width: 1920,
      height: 1080,
      canReencode: false,
    );
    expect(o.single.label, '원본');
  });
}
