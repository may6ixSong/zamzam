import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zamzam/ui/theme.dart';

void main() {
  Future<void> open(WidgetTester t, {required bool enabled}) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ConfirmLeave(
                  enabled: enabled,
                  message: 'm',
                  child: Scaffold(appBar: AppBar(), body: const Text('page')),
                ),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
  }

  testWidgets('back asks first and stays on 머무르기', (t) async {
    await open(t, enabled: true);
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    expect(find.text('이전 화면으로 갈까요?'), findsOneWidget);
    await t.tap(find.text('머무르기'));
    await t.pumpAndSettle();
    expect(find.text('page'), findsOneWidget);
  });

  testWidgets('back leaves on 나가기', (t) async {
    await open(t, enabled: true);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await t.tap(find.text('나가기'));
    await t.pumpAndSettle();
    expect(find.text('page'), findsNothing);
    expect(find.text('go'), findsOneWidget);
  });

  testWidgets('nothing loaded: leaves without asking', (t) async {
    await open(t, enabled: false);
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    expect(find.text('go'), findsOneWidget);
  });
}
