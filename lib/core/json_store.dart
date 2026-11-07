import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// JSON 하나를 읽고 쓰는 저장소. 테스트에서는 [MemoryJsonFile]로 바꿔 쓴다.
abstract class JsonFile {
  Future<Object?> read();
  Future<void> write(Object? value);
}

/// 앱 전용 폴더(Application Support)의 파일. 앱을 지우면 함께 지워진다.
class AppJsonFile implements JsonFile {
  AppJsonFile(this.name);

  final String name;
  Future<void> _queue = Future.value();

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$name');
  }

  @override
  Future<Object?> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(Object? value) {
    // 연달아 저장해도 순서대로 쓰고, 임시 파일에 쓴 뒤 바꿔 끼워 반쯤 쓴 파일이 남지 않게 한다.
    final text = jsonEncode(value);
    return _queue = _queue.then((_) async {
      try {
        final f = await _file();
        await f.parent.create(recursive: true);
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(f.path);
      } catch (_) {}
    });
  }
}

class MemoryJsonFile implements JsonFile {
  MemoryJsonFile([this.value]);

  Object? value;

  @override
  Future<Object?> read() async => value == null ? null : jsonDecode(jsonEncode(value));

  @override
  Future<void> write(Object? v) async => value = jsonDecode(jsonEncode(v));
}
