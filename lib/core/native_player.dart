import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// 안드로이드 기본 재생기(MediaPlayer)로 여는 미리보기.
///
/// video_player 의 플랫폼 인터페이스를 감싸, 주소가 [scheme]으로 시작하는 영상만 기본 재생기로 보내고
/// 나머지는 원래 재생기(ExoPlayer)가 그대로 맡는다. 그래서 화면 쪽은 같은 VideoPlayerController 를 쓴다.
class NativePlayerPlatform extends VideoPlayerPlatform {
  NativePlayerPlatform(this.inner) {
    _channel.setMethodCallHandler(_onNative);
  }

  /// 이 접두어가 붙은 주소(network 데이터 소스)는 기본 재생기로 연다.
  static const scheme = 'zamzam-native:';

  /// 원래 재생기 번호와 겹치지 않게 큰 수부터 쓴다.
  static const _base = 1 << 30;

  static const _channel = MethodChannel('zamzam/player');

  final VideoPlayerPlatform inner;
  final _events = <int, StreamController<VideoEvent>>{};
  final _textures = <int, int>{};

  /// 등록되기 전에 도착한 이벤트(만들기 응답보다 먼저 올 수 있다).
  final _early = <int, List<MethodCall>>{};

  /// 앱 시작 때 한 번 부른다.
  static void install() {
    final current = VideoPlayerPlatform.instance;
    if (current is NativePlayerPlatform) return;
    VideoPlayerPlatform.instance = NativePlayerPlatform(current);
  }

  bool _mine(int id) => id >= _base;
  int _nativeId(int id) => id - _base;

  Future<Object?> _onNative(MethodCall call) async {
    if (call.method != 'event') return null;
    final m = call.arguments as Map;
    final sink = _events[_base + (m['id'] as int)];
    if (sink == null) {
      (_early[m['id'] as int] ??= []).add(call);
      return null;
    }
    switch (m['type']) {
      case 'initialized':
        sink.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: Duration(milliseconds: (m['durationMs'] as num).toInt()),
            size: Size((m['width'] as num).toDouble(), (m['height'] as num).toDouble()),
            rotationCorrection: (m['rotation'] as num?)?.toInt() ?? 0,
          ),
        );
      case 'completed':
        sink.add(VideoEvent(eventType: VideoEventType.completed));
      case 'bufferingStart':
        sink.add(VideoEvent(eventType: VideoEventType.bufferingStart));
      case 'bufferingEnd':
        sink.add(VideoEvent(eventType: VideoEventType.bufferingEnd));
      case 'error':
        sink.addError(PlatformException(code: 'NATIVE_PLAYER', message: m['message'] as String?));
    }
    return null;
  }

  @override
  Future<void> init() => inner.init();

  Future<int?> _createNative(DataSource source) async {
    final uri = source.uri!.substring(scheme.length);
    final r = await _channel.invokeMapMethod<String, dynamic>('create', {'uri': uri});
    final id = _base + (r!['id'] as int);
    _textures[id] = (r['textureId'] as num).toInt();
    // 준비 완료 이벤트가 듣기 시작하기 전에 와도 잃지 않도록 버퍼가 있는 단일 구독 스트림을 쓴다.
    _events[id] = StreamController<VideoEvent>();
    for (final early in _early.remove(r['id'] as int) ?? const <MethodCall>[]) {
      await _onNative(early);
    }
    return id;
  }

  bool _isNative(DataSource s) => s.sourceType == DataSourceType.network && (s.uri ?? '').startsWith(scheme);

  @override
  // ignore: deprecated_member_use
  Future<int?> create(DataSource dataSource) =>
      // ignore: deprecated_member_use
      _isNative(dataSource) ? _createNative(dataSource) : inner.create(dataSource);

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) =>
      _isNative(options.dataSource) ? _createNative(options.dataSource) : inner.createWithOptions(options);

  @override
  Future<void> dispose(int playerId) async {
    if (!_mine(playerId)) return inner.dispose(playerId);
    _textures.remove(playerId);
    await _events.remove(playerId)?.close();
    await _channel.invokeMethod('dispose', {'id': _nativeId(playerId)});
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      _mine(playerId) ? _events[playerId]!.stream : inner.videoEventsFor(playerId);

  Future<void> _call(String method, int playerId, [Map<String, Object?> extra = const {}]) =>
      _channel.invokeMethod(method, {'id': _nativeId(playerId), ...extra});

  @override
  Future<void> setLooping(int playerId, bool looping) =>
      _mine(playerId) ? _call('setLooping', playerId, {'looping': looping}) : inner.setLooping(playerId, looping);

  @override
  Future<void> play(int playerId) async {
    if (!_mine(playerId)) return inner.play(playerId);
    await _call('play', playerId);
    _events[playerId]?.add(VideoEvent(eventType: VideoEventType.isPlayingStateUpdate, isPlaying: true));
  }

  @override
  Future<void> pause(int playerId) async {
    if (!_mine(playerId)) return inner.pause(playerId);
    await _call('pause', playerId);
    _events[playerId]?.add(VideoEvent(eventType: VideoEventType.isPlayingStateUpdate, isPlaying: false));
  }

  @override
  Future<void> setVolume(int playerId, double volume) =>
      _mine(playerId) ? _call('setVolume', playerId, {'volume': volume}) : inner.setVolume(playerId, volume);

  @override
  Future<void> seekTo(int playerId, Duration position) =>
      _mine(playerId) ? _call('seekTo', playerId, {'ms': position.inMilliseconds}) : inner.seekTo(playerId, position);

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) =>
      _mine(playerId) ? Future.value() : inner.setPlaybackSpeed(playerId, speed);

  @override
  Future<Duration> getPosition(int playerId) async {
    if (!_mine(playerId)) return inner.getPosition(playerId);
    final ms = await _channel.invokeMethod<int>('position', {'id': _nativeId(playerId)}) ?? 0;
    return Duration(milliseconds: ms);
  }

  @override
  Widget buildView(int playerId) {
    if (_mine(playerId)) return Texture(textureId: _textures[playerId]!);
    // ignore: deprecated_member_use
    return inner.buildView(playerId);
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      _mine(options.playerId) ? Texture(textureId: _textures[options.playerId]!) : inner.buildViewWithOptions(options);

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) => inner.setMixWithOthers(mixWithOthers);

  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) =>
      inner.setAllowBackgroundPlayback(allowBackgroundPlayback);

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(int playerId, bool preventsDisplaySleepDuringVideoPlayback) =>
      _mine(playerId)
      ? Future.value()
      : inner.setPreventsDisplaySleepDuringVideoPlayback(playerId, preventsDisplaySleepDuringVideoPlayback);

  @override
  Future<void> setWebOptions(int playerId, VideoPlayerWebOptions options) =>
      _mine(playerId) ? Future.value() : inner.setWebOptions(playerId, options);

  @override
  Future<List<VideoAudioTrack>> getAudioTracks(int playerId) =>
      _mine(playerId) ? Future.value(const <VideoAudioTrack>[]) : inner.getAudioTracks(playerId);

  @override
  Future<void> selectAudioTrack(int playerId, String trackId) =>
      _mine(playerId) ? Future.value() : inner.selectAudioTrack(playerId, trackId);

  @override
  bool isAudioTrackSupportAvailable() => inner.isAudioTrackSupportAvailable();

  @override
  Future<List<VideoTrack>> getVideoTracks(int playerId) =>
      _mine(playerId) ? Future.value(const <VideoTrack>[]) : inner.getVideoTracks(playerId);

  @override
  Future<void> selectVideoTrack(int playerId, VideoTrack? track) =>
      _mine(playerId) ? Future.value() : inner.selectVideoTrack(playerId, track);

  @override
  bool isVideoTrackSupportAvailable() => inner.isVideoTrackSupportAvailable();
}
