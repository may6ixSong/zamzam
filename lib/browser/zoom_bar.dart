import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// 화면 배율 조절 줄: [−] 슬라이드 [+] 125% [Fit] [닫기].
class ZoomBar extends StatelessWidget {
  const ZoomBar({
    super.key,
    required this.zoom,
    required this.onChanged,
    required this.onFit,
    required this.onClose,
    this.min = 0.5,
    this.max = 3.0,
  });

  final double zoom;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final VoidCallback onFit;
  final VoidCallback onClose;

  static const step = 0.1;

  @override
  Widget build(BuildContext context) {
    final percent = (zoom * 100).round();
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
      decoration: const BoxDecoration(
        color: Palette.s1,
        border: Border(bottom: BorderSide(color: Palette.line, width: .5)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '작게',
            visualDensity: VisualDensity.compact,
            onPressed: zoom <= min ? null : () => onChanged(zoom - step),
            icon: const Icon(Icons.remove_rounded, size: 20),
          ),
          Expanded(
            child: Slider(
              value: zoom.clamp(min, max),
              min: min,
              max: max,
              // 5% 단위.
              divisions: ((max - min) * 20).round(),
              label: '$percent%',
              // 기본 좌우 여백이 커서 슬라이드가 짧아진다.
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onChanged: onChanged,
            ),
          ),
          IconButton(
            tooltip: '크게',
            visualDensity: VisualDensity.compact,
            onPressed: zoom >= max ? null : () => onChanged(zoom + step),
            icon: const Icon(Icons.add_rounded, size: 20),
          ),
          SizedBox(
            width: 46,
            child: Text(
              '$percent%',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, fontFeatures: tabular),
            ),
          ),
          const SizedBox(width: 4),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              minimumSize: const Size(52, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: zoom == 1.0 ? null : onFit,
            child: const Text('Fit'),
          ),
          IconButton(
            tooltip: '닫기',
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}
