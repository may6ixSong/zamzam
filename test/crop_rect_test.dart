import 'package:flutter_test/flutter_test.dart';
import 'package:zamzam/core/crop_rect.dart';

void main() {
  test('비율 맞추기: 16:9 화면에서 1:1 은 가운데 세로 전체', () {
    final r = CropRect.fit(1, 16 / 9);
    expect(r.top, 0);
    expect(r.bottom, 1);
    expect(r.width, closeTo(9 / 16, 1e-9));
    expect(r.left, closeTo((1 - 9 / 16) / 2, 1e-9));
    // 픽셀로 보면 정사각형.
    expect(r.width * 1920 / (r.height * 1080), closeTo(1, 1e-9));
  });

  test('비율 맞추기: 세로 영상에서 16:9 는 가로 전체', () {
    final r = CropRect.fit(16 / 9, 1080 / 1920);
    expect(r.left, 0);
    expect(r.right, 1);
    expect(r.width * 1080 / (r.height * 1920), closeTo(16 / 9, 1e-9));
  });

  test('옮기기는 화면 밖으로 나가지 않는다', () {
    const r = CropRect(.2, .2, .6, .6);
    final m = r.move(.9, -.9);
    expect(m.right, 1);
    expect(m.top, 0);
    expect(m.width, closeTo(.4, 1e-9));
  });

  test('자유 크기 바꾸기: 반대 모서리는 그대로, 최소 크기 유지', () {
    const r = CropRect(.2, .2, .8, .8);
    final a = r.resize(2, .1, -.1);
    expect(a.left, .2);
    expect(a.top, .2);
    expect(a.right, closeTo(.9, 1e-9));
    expect(a.bottom, closeTo(.7, 1e-9));
    final tiny = r.resize(0, .9, .9);
    expect(tiny.width, closeTo(CropRect.minSize, 1e-9));
    expect(tiny.right, .8);
  });

  test('비율 고정 크기 바꾸기: 비율 유지, 화면 안', () {
    const ratio = 1.0; // 정규화 비율 1 = 화면과 같은 모양
    final r = CropRect.fit(16 / 9, 16 / 9).resize(0, .3, .1, normRatio: ratio);
    expect(r.width / r.height, closeTo(ratio, 1e-9));
    final big = const CropRect(.4, .4, .6, .6).resize(2, 2, 2, normRatio: ratio);
    expect(big.right, lessThanOrEqualTo(1));
    expect(big.bottom, lessThanOrEqualTo(1));
    expect(big.width / big.height, closeTo(ratio, 1e-9));
  });

  test('결과 크기는 짝수, 예상 용량은 원본보다 크지 않다', () {
    expect(cropOutputSize(1920, 1080, const CropRect(0, 0, .5, .5)), (960, 540));
    expect(cropOutputSize(1080, 1920, const CropRect(.1, .1, .433, .9)), (360, 1536));
    expect(estimateCropBytes(videoBytes: 100, audioBytes: 10, rect: CropRect.full), 110);
    expect(estimateCropBytes(videoBytes: 1000, audioBytes: 0, rect: const CropRect(0, 0, .5, .5)), 275);
  });
}
