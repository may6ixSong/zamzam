import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zamzam/browser/zoom_bar.dart';

void main() {
  testWidgets('배율 줄: +/− 는 10%씩, Fit 는 100%, 닫기', (tester) async {
    var zoom = 1.0;
    var closed = false;
    late StateSetter set;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (c, s) {
              set = s;
              return ZoomBar(
                zoom: zoom,
                onChanged: (v) => set(() => zoom = (v.clamp(.5, 3.0) * 100).roundToDouble() / 100),
                onFit: () => set(() => zoom = 1.0),
                onClose: () => closed = true,
              );
            },
          ),
        ),
      ),
    );
    expect(find.text('100%'), findsOneWidget);
    // 100%일 때는 Fit 가 꺼져 있다.
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Fit')).onPressed, isNull);
    await tester.tap(find.byTooltip('크게'));
    await tester.pump();
    await tester.tap(find.byTooltip('크게'));
    await tester.pump();
    expect(zoom, 1.2);
    expect(find.text('120%'), findsOneWidget);
    await tester.tap(find.byTooltip('작게'));
    await tester.pump();
    expect(zoom, 1.1);
    await tester.tap(find.widgetWithText(FilledButton, 'Fit'));
    await tester.pump();
    expect(zoom, 1.0);
    // 슬라이드를 끝까지 밀면 최대(300%).
    await tester.drag(find.byType(Slider), const Offset(600, 0));
    await tester.pump();
    expect(zoom, 3.0);
    await tester.tap(find.byTooltip('닫기'));
    expect(closed, isTrue);
  });
}
