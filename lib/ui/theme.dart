import 'package:flutter/material.dart';

/// 목업의 다크 팔레트.
abstract final class Palette {
  static const bg = Color(0xFF0D0E12);
  static const s1 = Color(0xFF17191F);
  static const s2 = Color(0xFF20232B);
  static const s3 = Color(0xFF2A2E38);
  static const line = Color(0xFF2F333D);
  static const text = Color(0xFFF2F3F6);
  static const muted = Color(0xFF9AA1AD);
  static const dim = Color(0xFF6B717C);
  static const accent = Color(0xFF5B8CFF);
  static const accentDeep = Color(0xFF3B6CF0);
  static const violet = Color(0xFF9B6BFF);
  static const trim = Color(0xFFFFC93C);
  static const ok = Color(0xFF3DD68C);
  static const bad = Color(0xFFFF6B6B);
}

/// 폴드 펼침 화면처럼 넓으면 2단 배치.
bool isExpanded(BoxConstraints c) => c.maxWidth >= 600;

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: Palette.accent,
      secondary: Palette.trim,
      surface: Palette.bg,
      error: Palette.bad,
    ),
    scaffoldBackgroundColor: Palette.bg,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: Palette.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Palette.text),
    ),
    dialogTheme: const DialogThemeData(backgroundColor: Palette.s1),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    textTheme: base.textTheme.apply(bodyColor: Palette.text, displayColor: Palette.text),
  );
}

const tabular = [FontFeature.tabularFigures()];

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.strong = false});

  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(color: Palette.s2, borderRadius: BorderRadius.circular(7)),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
        color: strong ? Palette.text : const Color(0xFFC5C9D1),
      ),
    ),
  );
}

class Badge2 extends StatelessWidget {
  const Badge2.ok(this.text, {super.key}) : color = Palette.ok, icon = Icons.check_rounded;
  const Badge2.bad(this.text, {super.key}) : color = Palette.bad, icon = Icons.warning_amber_rounded;

  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(color: color.withValues(alpha: .15), borderRadius: BorderRadius.circular(6)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color),
        ),
      ],
    ),
  );
}

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(color: Palette.s1, borderRadius: BorderRadius.circular(16)),
    child: child,
  );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.icon, this.onPressed, this.height = 54});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: Palette.accent,
        disabledBackgroundColor: Palette.s3,
        foregroundColor: Colors.white,
        disabledForegroundColor: const Color(0xFF6F7581),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 21),
      label: Text(label),
    ),
  );
}

class LosslessNote extends StatelessWidget {
  const LosslessNote({super.key, this.trailing = '원본은 그대로 남아요'});

  final String trailing;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 6,
    children: [
      const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_user_outlined, size: 14, color: Color(0xFF8FB0FF)),
          SizedBox(width: 3),
          Text(
            '무손실 · 재인코딩 없음',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFF8FB0FF)),
          ),
        ],
      ),
      Text('·  $trailing', style: const TextStyle(fontSize: 11.5, color: Palette.muted)),
    ],
  );
}

/// 시스템이 원본 대신 변환한 사본을 넘겨줬을 때의 경고.
class TranscodeWarning extends StatelessWidget {
  const TranscodeWarning({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: BoxDecoration(
      color: Palette.bad.withValues(alpha: .1),
      border: Border.all(color: Palette.bad.withValues(alpha: .35)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_rounded, color: Palette.bad, size: 18),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            '휴대폰이 원본 대신 다시 인코딩한 사본을 넘겨줬어요. 이대로 자르면 원본보다 용량이 커질 수 있어요.',
            style: TextStyle(fontSize: 12, height: 1.45, color: Color(0xFFFFD0D0)),
          ),
        ),
      ],
    ),
  );
}

/// 뒤로 가기(시스템 뒤로 가기·앱바 화살표 모두)를 누르면 확인을 받은 뒤 나간다. [enabled]가 아니면 바로 나간다.
class ConfirmLeave extends StatelessWidget {
  const ConfirmLeave({super.key, required this.enabled, required this.message, required this.child});

  final bool enabled;
  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !enabled,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      final navigator = Navigator.of(context);
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('이전 화면으로 갈까요?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          content: Text(message, style: const TextStyle(height: 1.5)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('머무르기')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('나가기')),
          ],
        ),
      );
      if (ok == true) navigator.pop();
    },
    child: child,
  );
}
