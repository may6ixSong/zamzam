import 'dart:async';

import 'package:flutter/services.dart';

import 'video_info.dart';

/// 저장 결과.
class ExportResult {
  const ExportResult({required this.uri, required this.name, required this.sizeBytes, required this.durationUs});

  final String uri;
  final String name;
  final int sizeBytes;
  final int durationUs;

  factory ExportResult.fromMap(Map<dynamic, dynamic> m) => ExportResult(
    uri: m['uri'] as String,
    name: m['name'] as String,
    sizeBytes: (m['size'] as num).toInt(),
    durationUs: (m['durationUs'] as num).toInt(),
  );
}

class ExportCancelled implements Exception {}

/// [converting]이면 화질 낮추기 중이고 received/total 은 퍼센트(0~100).
typedef DownloadProgress = ({String id, int received, int total, bool converting});

class DownloadResult {
  const DownloadResult({required this.uri, required this.name, required this.sizeBytes, required this.mime});

  /// Android: content:// 주소, iOS: 앱 폴더에 남겨 둔 사본 경로(자르기·합치기에 쓴다).
  final String uri;
  final String name;
  final int sizeBytes;
  final String mime;

  factory DownloadResult.fromMap(Map<dynamic, dynamic> m) => DownloadResult(
    uri: m['uri'] as String,
    name: m['name'] as String,
    sizeBytes: (m['size'] as num).toInt(),
    mime: m['mime'] as String? ?? 'video/mp4',
  );
}

/// 네이티브(Android: MediaExtractor/MediaMuxer, iOS: AVFoundation passthrough) 호출 창구.
/// 영상 데이터는 다시 인코딩하지 않고 그대로 복사한다.
class MediaEngine {
  MediaEngine._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        _progress.add((call.arguments as num).toDouble());
      } else if (call.method == 'downloadProgress') {
        final m = call.arguments as Map;
        _downloadProgress.add((
          id: m['id'] as String,
          received: (m['received'] as num).toInt(),
          total: (m['total'] as num).toInt(),
          converting: m['phase'] == 'convert',
        ));
      }
    });
  }

  static final MediaEngine instance = MediaEngine._();

  static const _channel = MethodChannel('zamzam/media');
  final _progress = StreamController<double>.broadcast();
  final _downloadProgress = StreamController<DownloadProgress>.broadcast();

  /// 내보내기 진행률(0~1).
  Stream<double> get progress => _progress.stream;

  /// 내려받기 진행(받은 바이트, 전체 바이트 — 모르면 -1).
  Stream<DownloadProgress> get downloadProgress => _downloadProgress.stream;

  /// [url]의 동영상을 내려받아 갤러리(Android Movies/ZamZam, iOS 사진 앱)에 바로 저장한다.
  /// [name]은 확장자 없는 파일 이름. 쿠키는 네이티브가 브라우저 저장소에서 붙인다.
  Future<DownloadResult> download({
    required String id,
    required String url,
    required String name,
    String? referer,
    String? userAgent,
    String? variantUrl,
    int? maxShortSide,
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('download', {
        'id': id,
        'url': url,
        'name': name,
        'referer': referer,
        'userAgent': userAgent,
        'variantUrl': variantUrl,
        'maxShortSide': maxShortSide,
      });
      return DownloadResult.fromMap(m!);
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') throw ExportCancelled();
      rethrow;
    }
  }

  /// 받기 전에 화질 목록·용량을 알아본다(Android). 결과는 [VideoInspection.fromMap]으로 읽는다.
  Future<Map<dynamic, dynamic>> inspectVideo(String url, {String? referer, String? userAgent}) async =>
      await _channel.invokeMapMethod<dynamic, dynamic>('inspectVideo', {
        'url': url,
        'referer': referer,
        'userAgent': userAgent,
      }) ??
      const {};

  /// 자르기가 안 되는 영상을 고친 사본(앱 임시 폴더의 file:// 주소)을 만든다. 원본은 그대로.
  /// 진행률은 [progress]로 온다.
  Future<String> repair(String uri) async {
    try {
      return (await _channel.invokeMethod<String>('repair', {'uri': uri}))!;
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') throw ExportCancelled();
      rethrow;
    }
  }

  /// 영상들을 갤러리 휴지통으로 옮긴다(Android 11+). 안드로이드가 확인 창을 띄운다.
  /// [moved]: 사용자가 허락해 옮겼는지, [skipped]: 찾지 못해 건너뛴 수(앱 임시 사본 등).
  Future<({bool moved, int count, int skipped})> trash(List<String> uris) async {
    final m = await _channel.invokeMapMethod<String, dynamic>('trash', {'uris': uris});
    return (
      moved: m?['moved'] == true,
      count: (m?['count'] as num?)?.toInt() ?? 0,
      skipped: (m?['skipped'] as num?)?.toInt() ?? 0,
    );
  }

  /// 소리가 안 나는 영상(브라우저로 받은 스트리밍 영상)을 고쳐 갤러리에 새 파일로 저장한다. 원본은 그대로.
  Future<ExportResult> repairToGallery(String uri) => _export('repair', {'uri': uri, 'toGallery': true});

  /// 갤러리의 영상을 짧은 변 [shortSide] 해상도로 낮춰 새 파일로 저장한다(Android, 진행률은 [progress]).
  Future<ExportResult> compress(String uri, {required int shortSide}) =>
      _export('compress', {'uri': uri, 'shortSide': shortSide});

  Future<void> cancelDownload(String id) => _channel.invokeMethod('cancelDownload', {'id': id});

  /// 갤러리에서 동영상을 고른다. 취소하면 빈 목록.
  Future<List<String>> pickVideos({required bool multiple}) async {
    final r = await _channel.invokeListMethod<String>('pickVideos', {'multiple': multiple});
    return r ?? const [];
  }

  Future<VideoInfo> probe(String uri) async {
    final m = await _channel.invokeMapMethod<String, dynamic>('probe', {'uri': uri});
    return VideoInfo.fromMap(m!);
  }

  /// 목록용 길이와 썸네일 한 장. 자르기·합치기의 영상 열기와 따로 처리돼 서로 기다리지 않는다.
  Future<({int durationUs, Uint8List? thumb})> listInfo(String uri, {int height = 160}) async {
    final m = await _channel.invokeMapMethod<String, dynamic>('listInfo', {'uri': uri, 'height': height});
    return (durationUs: (m?['durationUs'] as num?)?.toInt() ?? 0, thumb: m?['thumb'] as Uint8List?);
  }

  /// 타임라인용 썸네일(JPEG) [count]장.
  Future<List<Uint8List>> thumbnails(String uri, {required int count, required int height}) async {
    final r = await _channel.invokeListMethod<Uint8List>('thumbnails', {'uri': uri, 'count': count, 'height': height});
    return r ?? const [];
  }

  /// [us] 시점 화면 한 장(JPEG). [exact]가 아니면 가까운 키프레임이라 빠르다.
  Future<Uint8List?> frameAt(String uri, int us, {int height = 360, bool exact = false}) =>
      _channel.invokeMethod<Uint8List>('frameAt', {'uri': uri, 'us': us, 'height': height, 'exact': exact});

  /// [rotateCcw]: 왼쪽(반시계)으로 더 돌릴 각도(0/90/180/270). 회전 정보만 바꿔 무손실이다.
  Future<ExportResult> trim(String uri, {required int startUs, required int endUs, int rotateCcw = 0}) =>
      _export('trim', {'uri': uri, 'startUs': startUs, 'endUs': endUs, 'rotateCcw': rotateCcw});

  Future<ExportResult> merge(List<String> uris) => _export('merge', {'uris': uris});

  Future<void> cancel() => _channel.invokeMethod('cancel');

  /// 웹 페이지의 파일 올리기(Android). 고른 파일의 content:// 주소들.
  Future<List<String>> pickFiles(List<String> acceptTypes, {required bool multiple}) async =>
      await _channel.invokeListMethod<String>('pickFiles', {'accept': acceptTypes, 'multiple': multiple}) ?? const [];

  /// tel:, mailto:, intent: 같은 주소를 해당 앱으로 연다. 열 앱이 없으면 false.
  Future<bool> openExternal(String url) async =>
      await _channel.invokeMethod<bool>('openExternal', {'url': url}) ?? false;

  /// Android: 웹뷰의 모든 프레임에 페이지 시작 스크립트를 넣는다. 지원하지 않으면 false.
  Future<bool> installPageScript(int webViewId, String script) async =>
      await _channel.invokeMethod<bool>('installPageScript', {'webView': webViewId, 'script': script}) ?? false;

  Future<void> openInGallery(String uri) => _channel.invokeMethod('open', {'uri': uri});

  /// 저장 위치 안내 문구.
  Future<String> saveLocationLabel() async => await _channel.invokeMethod<String>('saveLocation') ?? 'Movies/ZamZam';

  Future<ExportResult> _export(String method, Map<String, Object?> args) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(method, args);
      return ExportResult.fromMap(m!);
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') throw ExportCancelled();
      rethrow;
    }
  }
}
