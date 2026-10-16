# ZamZam

재인코딩 없이 동영상을 **자르고 / 이어 붙이는** 모바일 앱(Flutter, Android·iOS).

- **자르기**: 시작·끝을 슬라이더나 시간 입력으로 정하면 그 구간만 새 파일로 저장한다.
  원본의 압축 데이터를 그대로 복사하므로 화질 손실이 없고 용량은 구간 길이에 비례한다.
  Android 는 시작점이 바로 앞 키프레임으로 맞춰진다(화면에 실제 시작 시각을 표시).
- **합치기**: 여러 영상을 골라 순서를 정하면 그대로 이어 붙인다. 코덱·해상도·방향·인코딩 설정·오디오
  형식이 첫 영상과 같아야 하며, 다르면 이유를 보여주고 막는다.
- 결과는 Android `Movies/ZamZam`, iOS 사진 앱에 저장된다. 원본은 건드리지 않는다.

## 구조

| 경로 | 내용 |
| --- | --- |
| `lib/core/` | 시간 표기·입력, 구간 규칙(끝 ≥ 시작 + 1초), 합치기 호환성 판정, 네이티브 채널 |
| `lib/ui/` | 메뉴 / 자르기 / 합치기 화면. 폭 600dp 이상(폴드 펼침)이면 2단 배치 |
| `android/.../MediaEngine.kt` | MediaExtractor → MediaMuxer 샘플 복사, MediaStore 저장, 시스템 사진 선택기 |
| `ios/Runner/AppDelegate.swift` | PHPicker, AVAssetExportSession(Passthrough), 사진 앱 저장 |

## 빌드

```sh
flutter test
flutter build apk --release
```

어느 브랜치에 push 하든 GitHub Actions 가 APK 를 만들어 Releases 에 올린다.
저장소 시크릿 `ZAMZAM_KEYSTORE_BASE64`, `ZAMZAM_KEYSTORE_PASSWORD`, `ZAMZAM_KEY_ALIAS`, `ZAMZAM_KEY_PASSWORD`
를 넣으면 매번 같은 키로 서명되어 앱을 지우지 않고 업데이트할 수 있다(없으면 빌드마다 다른 디버그 키).
