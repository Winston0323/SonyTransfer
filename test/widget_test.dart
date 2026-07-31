import 'package:flutter_test/flutter_test.dart';
import 'package:sony_transfer/main.dart';

void main() {
  testWidgets('opens on the camera setup instructions', (tester) async {
    await tester.pumpWidget(const SonyTransferApp());

    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Getting the camera ready'), findsOneWidget);
  });
}
