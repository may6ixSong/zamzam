import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/diag_log.dart';
import '../core/media_engine.dart';
import 'video_view.dart';

/// 문제 진단을 실행하고 결과를 보여 준 뒤 복사해 둔다.
///
/// [uris]마다 파일 정보·영상 정보 읽기·자르기 시험(앞/가운데 3초)·미리보기 재생기를 확인하고,
/// 최근 자르기 화면 기록([DiagLog])을 덧붙인다.
Future<void> runDiagnosis(BuildContext context, {required List<String> uris, String? note}) async {
  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            SizedBox(width: 16),
            Expanded(child: Text('진단하는 중… 자르기를 시험해 봐요 (최대 1분)')),
          ],
        ),
      ),
    ),
  );
  final out = StringBuffer();
  if (note != null) out.writeln(note);
  for (final (i, uri) in uris.indexed) {
    if (uris.length > 1) out.writeln(i == 0 ? '===== 원본 =====' : '===== 고친 사본 =====');
    try {
      out.writeln(await MediaEngine.instance.diagnose(uri));
    } catch (e) {
      out.writeln('진단 실패: $e');
    }
    final player = createController(uri);
    try {
      await player.initialize().timeout(const Duration(seconds: 20));
      final v = player.value;
      out.writeln('[재생기] 성공: ${v.size.width.round()}x${v.size.height.round()}, ${v.duration.inMilliseconds}ms');
    } catch (e) {
      out.writeln('[재생기] 실패: $e');
    } finally {
      await player.dispose();
    }
  }
  final log = DiagLog.lines;
  if (log.isNotEmpty) {
    out.writeln('===== 자르기 화면 기록 =====');
    log.forEach(out.writeln);
  }
  final text = out.toString().trim();
  navigator.pop();
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('진단 결과를 복사했어요'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('채팅에 그대로 붙여넣어 주세요.', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              SelectableText(text, style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace')),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: text)),
          child: const Text('다시 복사'),
        ),
        FilledButton(onPressed: () => Navigator.pop(c), child: const Text('확인')),
      ],
    ),
  );
}
