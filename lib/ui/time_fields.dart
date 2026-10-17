import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/time_format.dart';
import 'theme.dart';

/// 시·분·초를 칸별로 입력한다. 칸을 누르면 그 칸의 숫자를 바로 바꿀 수 있고(기존 값 전체 선택),
/// 두 자리를 치면 다음 칸으로 넘어간다. 세 칸 모두에서 포커스가 빠지면 [onSubmitted]로 알린다.
class TimeFields extends StatefulWidget {
  const TimeFields({super.key, required this.valueUs, required this.onSubmitted});

  final int valueUs;
  final ValueChanged<int> onSubmitted;

  @override
  State<TimeFields> createState() => _TimeFieldsState();
}

class _TimeFieldsState extends State<TimeFields> {
  final _ctrls = List.generate(3, (_) => TextEditingController());
  final _nodes = List.generate(3, (_) => FocusNode());
  static const _labels = ['시', '분', '초'];

  bool get _editing => _nodes.any((n) => n.hasFocus);

  @override
  void initState() {
    super.initState();
    _sync();
    for (var i = 0; i < 3; i++) {
      final node = _nodes[i];
      final ctrl = _ctrls[i];
      node.addListener(() {
        setState(() {});
        if (node.hasFocus) {
          ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
        } else {
          // 다른 칸으로 옮겨 간 게 아니라 입력을 마쳤을 때만 반영한다.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_editing) _commit();
          });
        }
      });
    }
  }

  @override
  void didUpdateWidget(TimeFields old) {
    super.didUpdateWidget(old);
    if (old.valueUs != widget.valueUs && !_editing) _sync();
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _sync() {
    final total = widget.valueUs ~/ usPerSecond;
    final parts = [total ~/ 3600, (total % 3600) ~/ 60, total % 60];
    for (var i = 0; i < 3; i++) {
      _ctrls[i].text = parts[i].toString().padLeft(2, '0');
    }
  }

  void _commit() {
    int read(int i) => int.tryParse(_ctrls[i].text) ?? 0;
    final seconds = read(0) * 3600 + read(1) * 60 + read(2);
    if (seconds != widget.valueUs ~/ usPerSecond) {
      widget.onSubmitted(seconds * usPerSecond);
    }
    // 부모가 규칙에 맞게 고친 값이 다시 들어오면 그 값으로, 아니면 두 자리 형식으로 정리한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_editing) _sync();
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget field(int i) {
      final focused = _nodes[i].hasFocus;
      return Expanded(
        child: Column(
          children: [
            TextField(
              controller: _ctrls[i],
              focusNode: _nodes[i],
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              textInputAction: i < 2 ? TextInputAction.next : TextInputAction.done,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
              onChanged: (v) {
                if (v.length == 2) {
                  i < 2 ? _nodes[i + 1].requestFocus() : _nodes[i].unfocus();
                }
              },
              onSubmitted: (_) => i < 2 ? _nodes[i + 1].requestFocus() : _nodes[i].unfocus(),
              onTap: () => _ctrls[i].selection = TextSelection(baseOffset: 0, extentOffset: _ctrls[i].text.length),
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, fontFeatures: tabular),
              cursorColor: Palette.trim,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: focused ? Palette.trim.withValues(alpha: .08) : Palette.s2,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Palette.line, width: 1.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Palette.trim, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 3),
            Text(_labels[i], style: TextStyle(fontSize: 10.5, color: focused ? Palette.trim : Palette.dim)),
          ],
        ),
      );
    }

    const colon = Padding(
      padding: EdgeInsets.fromLTRB(3, 8, 3, 0),
      child: Text(
        ':',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Palette.muted),
      ),
    );
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [field(0), colon, field(1), colon, field(2)]);
  }
}
