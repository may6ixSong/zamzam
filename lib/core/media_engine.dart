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

/// 네이티브(Android: MediaExtractor/MediaMuxer, iOS: AVFoundation passthrough) 호출 창구.
/// 영상 데이터는 다시 인코딩하지 않고 그대로 복사한다.
class MediaEngine {
  MediaEngine._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        _progress.add((call.arguments as num).toDouble());
      }
    });
  }

  static final MediaEngine instance = MediaEngine._();

  static const _channel = MethodChannel('zamzam/media');
  final _progress = StreamController<double>.broadcast();

  /// 내보내기 진행률(0~1).
  Stream<double> get progress => _progress.stream;

  /// 갤러리에서 동영상을 고른다. 취소하면 빈 목록.
  Future<List<String>> pickVideos({required bool multiple}) async {
    final r = await _channel.invokeListMethod<String>('pickVideos', {'multiple': multiple});
    return r ?? const [];
  }

  Future<VideoInfo> probe(String uri) async {
    final m = await _channel.invokeMapMethod<String, dynamic>('probe', {'uri': uri});
    return VideoInfo.fromMap(m!);
  }

  /// 타임라인용 썸네일(JPEG) [count]장.
  Future<List<Uint8List>> thumbnails(String uri, {required int count, required int height}) async {
    final r = await _channel.invokeListMethod<Uint8List>('thumbnails', {'uri': uri, 'count': count, 'height': height});
    return r ?? const [];
  }

  /// [rotateCcw]: 왼쪽(반시계)으로 더 돌릴 각도(0/90/180/270). 회전 정보만 바꿔 무손실이다.
  Future<ExportResult> trim(String uri, {required int startUs, required int endUs, int rotateCcw = 0}) =>
      _export('trim', {'uri': uri, 'startUs': startUs, 'endUs': endUs, 'rotateCcw': rotateCcw});

  Future<ExportResult> merge(List<String> uris) => _export('merge', {'uris': uris});

  Future<void> cancel() => _channel.invokeMethod('cancel');

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
