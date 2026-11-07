import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'json_store.dart';
import 'media_engine.dart';

/// 내려받아 갤러리에 저장한 동영상 한 건.
class DownloadItem {
  const DownloadItem({
    required this.id,
    required this.uri,
    required this.name,
    required this.sizeBytes,
    required this.sourceUrl,
    required this.pageUrl,
    required this.time,
  });

  final String id;

  /// 자르기·합치기에 넘기는 주소(Android content://, iOS 앱 폴더의 사본 경로).
  final String uri;
  final String name;
  final int sizeBytes;
  final String sourceUrl;
  final String pageUrl;
  final DateTime time;

  /// iOS 처럼 앱 폴더에 사본을 둔 경우. 기록을 지우면 사본도 지운다(사진 앱의 영상은 남는다).
  bool get isAppCopy => uri.startsWith('/');

  Map<String, Object?> toJson() => {
    'id': id,
    'uri': uri,
    'name': name,
    'size': sizeBytes,
    'src': sourceUrl,
    'page': pageUrl,
    't': time.millisecondsSinceEpoch,
  };

  static DownloadItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final uri = j['uri'];
    if (id is! String || uri is! String) return null;
    return DownloadItem(
      id: id,
      uri: uri,
      name: j['name'] as String? ?? '',
      sizeBytes: (j['size'] as num?)?.toInt() ?? 0,
      sourceUrl: j['src'] as String? ?? '',
      pageUrl: j['page'] as String? ?? '',
      time: DateTime.fromMillisecondsSinceEpoch((j['t'] as num?)?.toInt() ?? 0),
    );
  }
}

enum TaskState { running, failed, cancelled }

/// 진행 중이거나 실패한 내려받기.
class DownloadTask {
  DownloadTask({required this.id, required this.url, required this.name, required this.pageUrl, this.userAgent});

  final String id;
  final String url;
  final String name;
  final String pageUrl;
  final String? userAgent;
  int received = 0;
  int total = -1;
  TaskState state = TaskState.running;
  String? error;

  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

/// 다운로드 목록(완료 기록 + 진행 중인 작업). 앱 전체에서 하나만 쓴다.
class Downloads extends ChangeNotifier {
  Downloads({JsonFile? file, MediaEngine? engine, this.deleteAppCopy = _deleteFile})
    : _file = file ?? AppJsonFile('downloads.json'),
      _engineOverride = engine;

  static final Downloads instance = Downloads();

  final JsonFile _file;
  final MediaEngine? _engineOverride;
  final Future<void> Function(String path) deleteAppCopy;
  final List<DownloadItem> _items = [];
  final List<DownloadTask> _tasks = [];
  StreamSubscription<DownloadProgress>? _sub;
  bool _loaded = false;
  int _seq = 0;

  MediaEngine get _engine => _engineOverride ?? MediaEngine.instance;

  /// 최근 것이 앞.
  List<DownloadItem> get items => List.unmodifiable(_items);
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  int get runningCount => _tasks.where((t) => t.state == TaskState.running).length;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final j = await _file.read();
    if (j is List) _items.addAll(j.map(DownloadItem.fromJson).whereType<DownloadItem>());
    notifyListeners();
  }

  /// 내려받기를 시작한다. 끝나면 목록에 들어가고 완료된 항목을 돌려준다(실패·취소면 null).
  Future<DownloadItem?> start({
    required String url,
    required String name,
    required String pageUrl,
    String? userAgent,
  }) async {
    await load();
    _sub ??= _engine.downloadProgress.listen(_onProgress);
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';
    final task = DownloadTask(id: id, url: url, name: name, pageUrl: pageUrl, userAgent: userAgent);
    _tasks.insert(0, task);
    notifyListeners();
    try {
      final r = await _engine.download(
        id: id,
        url: url,
        name: name,
        referer: pageUrl.isEmpty ? null : pageUrl,
        userAgent: userAgent,
      );
      _tasks.remove(task);
      final item = DownloadItem(
        id: id,
        uri: r.uri,
        name: r.name,
        sizeBytes: r.sizeBytes,
        sourceUrl: url,
        pageUrl: pageUrl,
        time: DateTime.now(),
      );
      add(item);
      return item;
    } on ExportCancelled {
      task.state = TaskState.cancelled;
      _tasks.remove(task);
      notifyListeners();
    } on PlatformException catch (e) {
      task
        ..state = TaskState.failed
        ..error = e.message ?? e.code;
      notifyListeners();
    } catch (e) {
      task
        ..state = TaskState.failed
        ..error = '$e';
      notifyListeners();
    }
    return null;
  }

  /// 완료 기록 하나를 맨 앞에 넣는다.
  void add(DownloadItem item) {
    _items.removeWhere((e) => e.id == item.id);
    _items.insert(0, item);
    _save();
  }

  Future<void> cancel(DownloadTask task) async {
    if (task.state == TaskState.running) {
      await _engine.cancelDownload(task.id);
    } else {
      _tasks.remove(task);
      notifyListeners();
    }
  }

  Future<DownloadItem?> retry(DownloadTask task) {
    _tasks.remove(task);
    return start(url: task.url, name: task.name, pageUrl: task.pageUrl, userAgent: task.userAgent);
  }

  /// 목록에서만 지운다. 갤러리에 저장된 영상은 그대로 둔다.
  Future<void> remove(DownloadItem item) async {
    _items.removeWhere((e) => e.id == item.id);
    if (item.isAppCopy) await deleteAppCopy(item.uri);
    _save();
  }

  /// 다운로드 이력을 전부 지운다(진행 중인 것은 그대로, 실패한 것은 함께 지움).
  Future<void> clearAll() async {
    final copies = _items.where((e) => e.isAppCopy).map((e) => e.uri).toList();
    _items.clear();
    _tasks.removeWhere((t) => t.state != TaskState.running);
    _save();
    for (final p in copies) {
      await deleteAppCopy(p);
    }
  }

  void _onProgress(DownloadProgress p) {
    for (final t in _tasks) {
      if (t.id == p.id) {
        t
          ..received = p.received
          ..total = p.total;
        notifyListeners();
        return;
      }
    }
  }

  void _save() {
    notifyListeners();
    _file.write(_items.map((e) => e.toJson()).toList());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

Future<void> _deleteFile(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
    // iOS 는 다운로드마다 폴더를 하나 만든다. 비었으면 같이 지운다.
    final dir = f.parent;
    if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
  } catch (_) {}
}
