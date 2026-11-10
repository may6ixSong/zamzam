import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/media_engine.dart';
import 'export_flow.dart';
import 'theme.dart';

/// 확인을 받은 뒤 영상들을 갤러리 휴지통으로 옮긴다(완전 삭제 아님, 30일 안에 되살릴 수 있다).
/// 안드로이드도 한 번 더 확인 창을 띄운다. 옮겼으면 true.
Future<bool> confirmAndTrash(
  BuildContext context, {
  required List<String> uris,
  required String what,
  required String keeps,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.delete_outline_rounded, color: Palette.bad, size: 36),
      title: Text(
        '${objectParticle(what)} 휴지통으로 옮길까요?',
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
      ),
      content: Text('갤러리 휴지통으로 옮겨요. 30일 안에는 갤러리 휴지통에서 되살릴 수 있어요.\n$keeps', style: const TextStyle(height: 1.55)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          style: FilledButton.styleFrom(backgroundColor: Palette.bad, foregroundColor: Colors.white),
          child: const Text('휴지통으로'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  String message;
  var moved = false;
  try {
    final r = await MediaEngine.instance.trash(uris);
    moved = r.moved;
    message = r.moved
        ? '${objectParticle(what)} 휴지통으로 옮겼어요${r.skipped > 0 ? ' (${r.skipped}개는 찾지 못해 건너뜀)' : ''}'
        : (r.count == 0 ? '휴지통으로 옮길 영상을 갤러리에서 찾지 못했어요' : '휴지통으로 옮기지 않았어요');
  } on PlatformException catch (e) {
    message = e.message ?? '휴지통으로 옮기지 못했어요';
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
  return moved;
}
