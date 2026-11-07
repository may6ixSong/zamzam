# ZamZam

동영상을 **길게 눌러 바로 갤러리에 받는 인터넷 브라우저** + 재인코딩 없는 **자르기 / 이어 붙이기** (Flutter, Android·iOS).

## 브라우저 (첫 화면)

- 주소·검색(구글/네이버/다음), 탭 여러 개, 뒤로·앞으로·새로고침·중지, 홈(시작 페이지)
- 북마크, 방문 기록(날짜별·개별/전체 삭제), 주소창 추천, 공유·주소 복사
- 데스크톱 사이트 보기, 인터넷 사용 기록 삭제(기록·캐시·쿠키), 파일 올리기, 동영상 전체 화면,
  `tel:`·`intent:` 같은 앱 주소는 해당 앱으로
- **동영상 길게 누르기 → 갤러리에 다운로드**. 브라우저의 쿠키·User-Agent·Referer 를 그대로 붙여 받는다.
  재생 버튼 같은 덮개 아래 동영상도 찾는다. 메뉴의 "이 페이지의 동영상 찾기"로 목록에서 고를 수도 있다.
  - 받을 수 있는 것: mp4·webm·mov 같은 **파일 주소**의 동영상
  - 받을 수 없는 것: 조각 스트리밍(blob:, HLS `.m3u8`, DASH) — 유튜브 등 대형 사이트 대부분. 이유를 안내한다.

## 동영상 다운로드 목록

- 받은 영상은 바로 갤러리(Android `Movies/ZamZam`, iOS 사진 앱)에 저장되고 목록에 쌓인다.
- 진행률·취소·다시 시도, 항목별 **자르기 / 합치기**(여러 개를 누른 순서대로), 갤러리에서 보기.
- **다운로드 이력 전부 지우기**: 목록만 지우고 갤러리의 영상은 남긴다.
  (iOS 는 자르기·합치기용으로 앱 폴더에 둔 사본도 함께 지운다.)

## 자르기·합치기 (기존 기능, 다운로드 목록 또는 메뉴 → 동영상 편집)

## 구조

| 경로 | 내용 |
| --- | --- |
| `lib/browser/` | 브라우저 화면·탭·시작 페이지·북마크/기록, 동영상 길게 누르기 스크립트(`page_scripts.dart`) |
| `lib/core/` | 시간 표기·입력, 구간 규칙(끝 ≥ 시작 + 1초), 합치기 호환성 판정, 주소/검색 판별, 북마크·기록·다운로드 목록 저장, 네이티브 채널 |
| `lib/ui/` | 다운로드 목록 / 편집 메뉴 / 자르기 / 합치기 화면. 폭 600dp 이상(폴드 펼침)이면 2단 배치 |
| `android/.../MediaEngine.kt` | MediaExtractor → MediaMuxer 샘플 복사, MediaStore 저장, 시스템 사진 선택기, 동영상 내려받기(MediaStore 에 바로 기록) |
| `ios/Runner/AppDelegate.swift` | PHPicker, AVAssetExportSession(Passthrough), 사진 앱 저장, 동영상 내려받기(URLSession) |

## 빌드

```sh
flutter test
flutter build apk --release
```

어느 브랜치에 push 하든 GitHub Actions 가 APK 를 만들어 Releases 에 올린다.
저장소 시크릿 `ZAMZAM_KEYSTORE_BASE64`, `ZAMZAM_KEYSTORE_PASSWORD`, `ZAMZAM_KEY_ALIAS`, `ZAMZAM_KEY_PASSWORD`
를 넣으면 매번 같은 키로 서명되어 앱을 지우지 않고 업데이트할 수 있다(없으면 빌드마다 다른 디버그 키).
