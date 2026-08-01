import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sony_transfer/models/camera_item.dart';
import 'package:sony_transfer/models/timeline.dart';
import 'package:sony_transfer/widgets/preview_page.dart';
import 'package:sony_transfer/widgets/timeline_view.dart';

/// Dates are kept far in the past on purpose: recent ones render as "Today" or
/// "Yesterday", which would make these tests depend on the wall clock.
CameraItem _shot(String name, {DateTime? at, bool raw = false}) => CameraItem(
      id: name,
      title: name,
      folder: '100MSDCF',
      captured: at,
      resources: [
        CameraResource(
          url: 'http://camera/$name',
          byteSize: raw ? null : 1000,
          protocolInfo: 'http-get:*:image/jpeg:*',
        ),
      ],
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<CameraItem> items,
  required Set<String> selected,
  required ValueChanged<CameraItem> onToggle,
  ValueChanged<TimelineSection>? onToggleDay,
  bool loadingMore = false,
}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimelineView(
            sections: groupIntoTimeline(items),
            selected: selected,
            outcomes: const {},
            loadingMore: loadingMore,
            onToggle: onToggle,
            onToggleDay: onToggleDay ?? (_) {},
          ),
        ),
      ),
    );

void main() {
  testWidgets('renders a header per day, newest first', (tester) async {
    await _pump(
      tester,
      items: [
        _shot('a.JPG', at: DateTime(2020, 5, 30, 9)),
        _shot('b.JPG', at: DateTime(2020, 5, 28, 9)),
      ],
      selected: {},
      onToggle: (_) {},
    );

    final headers = tester
        .widgetList<Text>(find.textContaining('2020-05'))
        .map((t) => t.data)
        .toList();
    expect(headers, ['2020-05-30', '2020-05-28']);
  });

  testWidgets('the corner box reports a shot for selection', (tester) async {
    final tapped = <String>[];

    await _pump(
      tester,
      items: [_shot('a.JPG', at: DateTime(2020, 5, 30, 9))],
      selected: {},
      onToggle: (i) => tapped.add(i.id),
    );

    await tester.tap(find.byIcon(Icons.circle_outlined));

    expect(tapped, ['a.JPG']);
    // Selecting must not also open the preview.
    await tester.pumpAndSettle();
    expect(find.byType(PreviewPage), findsNothing);
  });

  testWidgets('long-pressing a shot selects it too', (tester) async {
    final tapped = <String>[];

    await _pump(
      tester,
      items: [_shot('a.JPG', at: DateTime(2020, 5, 30, 9))],
      selected: {},
      onToggle: (i) => tapped.add(i.id),
    );

    await tester.longPress(find.byType(Image));

    expect(tapped, ['a.JPG']);
  });

  testWidgets('a raw shot is badged and offers no select box', (tester) async {
    final tapped = <String>[];

    await _pump(
      tester,
      items: [_shot('a.ARW', at: DateTime(2020, 5, 30, 9), raw: true)],
      selected: {},
      onToggle: (i) => tapped.add(i.id),
    );

    expect(find.text('RAW'), findsOneWidget);
    expect(find.byIcon(Icons.circle_outlined), findsNothing);

    await tester.longPress(find.text('RAW'));
    expect(tapped, isEmpty);
  });

  testWidgets('the day header toggles that day only', (tester) async {
    TimelineSection? toggled;

    await _pump(
      tester,
      items: [
        _shot('a.JPG', at: DateTime(2020, 5, 30, 9)),
        _shot('b.JPG', at: DateTime(2020, 5, 28, 9)),
      ],
      selected: {},
      onToggle: (_) {},
      onToggleDay: (section) => toggled = section,
    );

    await tester.tap(find.text('All').first);
    expect(toggled!.items.single.id, 'a.JPG');
  });

  testWidgets('the header offers to clear a fully selected day',
      (tester) async {
    await _pump(
      tester,
      items: [_shot('a.JPG', at: DateTime(2020, 5, 30, 9))],
      selected: {'a.JPG'},
      onToggle: (_) {},
    );

    expect(find.text('None'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('tapping a shot opens the full-screen preview page',
      (tester) async {
    await _pump(
      tester,
      items: [_shot('a.JPG', at: DateTime(2020, 5, 30, 9))],
      selected: {},
      onToggle: (_) {},
    );

    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();

    expect(find.byType(PreviewPage), findsOneWidget);
    expect(find.text('a.JPG'), findsOneWidget);
    expect(find.text('1 / 1'), findsOneWidget);
  });

  testWidgets('swiping the preview moves to the next shot in grid order',
      (tester) async {
    await _pump(
      tester,
      items: [
        _shot('a.JPG', at: DateTime(2020, 5, 30, 9)),
        _shot('b.JPG', at: DateTime(2020, 5, 30, 8)),
      ],
      selected: {},
      onToggle: (_) {},
    );

    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.text('a.JPG'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(find.text('b.JPG'), findsOneWidget);
    expect(find.text('2 / 2'), findsOneWidget);
  });

  testWidgets('the preview can select the shot it is showing', (tester) async {
    final tapped = <String>[];

    await _pump(
      tester,
      items: [_shot('a.JPG', at: DateTime(2020, 5, 30, 9))],
      selected: {},
      onToggle: (i) => tapped.add(i.id),
    );

    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();

    expect(tapped, ['a.JPG']);
    expect(find.text('Selected'), findsOneWidget);
  });

  testWidgets('the preview of a raw shot offers no select action',
      (tester) async {
    await _pump(
      tester,
      items: [_shot('a.ARW', at: DateTime(2020, 5, 30, 9), raw: true)],
      selected: {},
      onToggle: (_) {},
    );

    await tester.tap(find.text('RAW'));
    await tester.pumpAndSettle();

    expect(find.textContaining('raw, preview only'), findsOneWidget);
    expect(find.text('Select'), findsNothing);
  });

  testWidgets('says so while older shots are still arriving', (tester) async {
    await _pump(
      tester,
      items: [_shot('a.JPG', at: DateTime(2020, 5, 30, 9))],
      selected: {},
      onToggle: (_) {},
      loadingMore: true,
    );

    expect(find.text('Loading older shots'), findsOneWidget);
  });

  testWidgets('drops the footer once the card is fully listed', (tester) async {
    await _pump(
      tester,
      items: [_shot('a.JPG', at: DateTime(2020, 5, 30, 9))],
      selected: {},
      onToggle: (_) {},
    );

    expect(find.text('Loading older shots'), findsNothing);
  });

}
