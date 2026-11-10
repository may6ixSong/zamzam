import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/diag_log.dart';
import '../core/media_engine.dart';
import '../core/time_format.dart';
import 'theme.dart';

/// 진행률 다이얼로그를 띄운 채 [job]을 실행하고, 끝나면 결과를 보여준다. 저장에 성공하면 true.
Future<bool> runExport(
  BuildContext context, {
  required String title,
  required Future<ExportResult> Function() job,
  String detail = '원본 데이터를 그대로 복사하는 중',
  List<String> trashUris = const [],
  String trashLabel = '원본 영상',
}) async {
  final engine = MediaEngine.instance;
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: _ProgressDialog(title: title, detail: detail, progress: engine.progress),
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
  DiagLog.add(
    result != null
        ? '$title 성공: ${result.name}, ${result.sizeBytes}바이트, ${result.durationUs}us'
        : '$title 실패: ${error ?? '취소'}',
  );
  if (result != null) {
    if (!context.mounted) return true;
    await showDialog<void>(
      context: context,
      builder: (_) => _DoneDialog(result: result!, trashUris: trashUris, trashLabel: trashLabel),
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
  const _ProgressDialog({required this.title, required this.detail, required this.progress});

  final String title;
  final String detail;
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
            Text('${(v * 100).round()}% · $detail', style: const TextStyle(fontSize: 12.5, color: Palette.muted)),
          ],
        );
      },
    ),
    actions: [TextButton(onPressed: MediaEngine.instance.cancel, child: const Text('취소'))],
  );
}

/// 받침에 맞춰 '을/를'을 붙인다(예: 원본 영상을, 조각 3개를).
String objectParticle(String word) {
  if (word.isEmpty) return word;
  final c = word.codeUnitAt(word.length - 1);
  if (c < 0xAC00 || c > 0xD7A3) return '$word을(를)';
  return (c - 0xAC00) % 28 == 0 ? '$word를' : '$word을';
}

class _DoneDialog extends StatefulWidget {
  const _DoneDialog({required this.result, required this.trashUris, required this.trashLabel});

  final ExportResult result;

  /// 저장한 뒤 휴지통으로 옮길 수 있는 영상(자르기의 원본, 합치기의 조각들). 비면 버튼을 숨긴다.
  final List<String> trashUris;
  final String trashLabel;

  @override
  State<_DoneDialog> createState() => _DoneDialogState();
}

class _DoneDialogState extends State<_DoneDialog> {
  bool _busy = false;
  String? _trashed;

  /// 휴지통으로 옮긴다. 안드로이드가 확인 창을 띄우고, 휴지통에서 30일 안에 되살릴 수 있다.
  Future<void> _trash() async {
    setState(() => _busy = true);
    String message;
    try {
      final r = await MediaEngine.instance.trash(widget.trashUris);
      message = r.moved
          ? '${objectParticle(widget.trashLabel)} 휴지통으로 옮겼어요${r.skipped > 0 ? ' (${r.skipped}개는 찾지 못해 건너뜀)' : ''}'
          : (r.count == 0 ? '휴지통으로 옮길 영상을 갤러리에서 찾지 못했어요' : '휴지통으로 옮기지 않았어요');
    } on PlatformException catch (e) {
      message = e.message ?? '휴지통으로 옮기지 못했어요';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _trashed = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final canTrash = widget.trashUris.isNotEmpty && defaultTargetPlatform == TargetPlatform.android;
    return AlertDialog(
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
          if (canTrash) ...[
            const SizedBox(height: 16),
            if (_trashed != null)
              Text(
                _trashed!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Palette.muted),
              )
            else
              OutlinedButton.icon(
                onPressed: _busy ? null : _trash,
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.delete_outline_rounded, size: 18, color: Palette.bad),
                label: Text('${objectParticle(widget.trashLabel)} 휴지통으로'),
              ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => MediaEngine.instance.openInGallery(result.uri), child: const Text('열어 보기')),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('확인')),
      ],
    );
  }
}
