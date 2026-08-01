import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sony_transfer/main.dart';

void main() {
  testWidgets('opens on the camera setup instructions', (tester) async {
    await tester.pumpWidget(const SonyTransferApp());

    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);

    // The setup panel and instructions now share a single scroll region, so
    // the instructions can start below the fold on a short test surface.
    await tester.scrollUntilVisible(
      find.text('Getting the camera ready'),
      500,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Getting the camera ready'), findsOneWidget);
  });
}
