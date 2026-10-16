import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/media_engine.dart';
import '../core/time_format.dart';
import 'theme.dart';

/// 진행률 다이얼로그를 띄운 채 [job]을 실행하고, 끝나면 결과를 보여준다. 저장에 성공하면 true.
Future<bool> runExport(
  BuildContext context, {
  required String title,
  required Future<ExportResult> Function() job,
}) async {
  final engine = MediaEngine.instance;
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: _ProgressDialog(title: title, progress: engine.progress),
    ),
  );
  ExportResult? result;
  String? error;
  try {
    result = await job();
  } on ExportCancelled {
    error = null;
  } on PlatformException catch (e) {
    error = e.message ?? e.code;
  } catch (e) {
    error = '$e';
  }
  navigator.pop();
  if (result != null) {
    if (!context.mounted) return true;
    await showDialog<void>(
      context: context,
      builder: (_) => _DoneDialog(result: result!),
    );
    return true;
  } else if (error != null) {
    messenger.showSnackBar(SnackBar(content: Text('만들지 못했어요: $error')));
  } else {
    messenger.showSnackBar(const SnackBar(content: Text('취소했어요')));
  }
  return false;
}

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({required this.title, required this.progress});

  final String title;
  final Stream<double> progress;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
    content: StreamBuilder<double>(
      stream: progress,
      initialData: 0,
      builder: (_, snap) {
        final v = (snap.data ?? 0).clamp(0.0, 1.0);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(
              value: v,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
              backgroundColor: Palette.s3,
            ),
            const SizedBox(height: 10),
            Text(
              '${(v * 100).round()}% · 원본 데이터를 그대로 복사하는 중',
              style: const TextStyle(fontSize: 12.5, color: Palette.muted),
            ),
          ],
        );
      },
    ),
    actions: [TextButton(onPressed: MediaEngine.instance.cancel, child: const Text('취소'))],
  );
}

class _DoneDialog extends StatelessWidget {
  const _DoneDialog({required this.result});

  final ExportResult result;

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.check_circle_rounded, color: Palette.ok, size: 40),
    title: const Text('저장했어요', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          result.name,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          '${formatTime(result.durationUs)} · ${formatBytes(result.sizeBytes)}',
          style: const TextStyle(color: Palette.muted, fontFeatures: tabular),
        ),
        const SizedBox(height: 4),
        FutureBuilder(
          future: MediaEngine.instance.saveLocationLabel(),
          builder: (_, s) => Text('저장 위치: ${s.data ?? ''}', style: const TextStyle(fontSize: 12, color: Palette.dim)),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => MediaEngine.instance.openInGallery(result.uri), child: const Text('열어 보기')),
      FilledButton(onPressed: () => Navigator.pop(context), child: const Text('확인')),
    ],
  );
}
