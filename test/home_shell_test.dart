import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sony_transfer/screens/home_shell.dart';
import 'package:sony_transfer/screens/monitor_screen.dart';
import 'package:sony_transfer/screens/transfer_screen.dart';
import 'package:sony_transfer/services/transfer_service.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sony_transfer_shell_test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Widget app() => MaterialApp(
        home: HomeShell(transferService: TransferService(destination: temp)),
      );

  testWidgets(
    'going back to the album hides the transfer flow without disposing it, '
    'so the camera connection survives',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();

      // Not even built until first opened — the album alone should not start
      // Wi-Fi scanning.
      expect(find.byType(TransferScreen, skipOffstage: false), findsNothing);

      await tester.tap(find.byTooltip('Connect camera'));
      await tester.pump();
      expect(find.text('Not connected'), findsOneWidget);

      final state = tester.state(find.byType(TransferScreen));

      await tester.tap(find.byType(BackButton));
      await tester.pump();
      expect(find.byTooltip('Connect camera'), findsOneWidget);

      // The whole point: still alive offstage. Disposing it would run its
      // teardown, which drops the camera's Wi-Fi.
      expect(
        tester.state(find.byType(TransferScreen, skipOffstage: false)),
        same(state),
      );

      // Reopening resumes the very same instance — connection, shot list,
      // selection and all.
      await tester.tap(find.byTooltip('Connect camera'));
      await tester.pump();
      expect(tester.state(find.byType(TransferScreen)), same(state));
    },
  );

  testWidgets(
    'the live monitor stays alive behind the album, so a copy is not cut '
    'by going back',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();

      expect(find.byType(MonitorScreen, skipOffstage: false), findsNothing);

      await tester.tap(find.byTooltip('Live monitor'));
      await tester.pump();
      // The setup steps can push the button below the fold on the test surface.
      await tester.scrollUntilVisible(
        find.text('Start monitor'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Start monitor'), findsOneWidget);

      final state = tester.state(find.byType(MonitorScreen));
      await tester.pump();

      await tester.tap(find.byType(BackButton));
      await tester.pump();
      expect(find.byTooltip('Live monitor'), findsOneWidget);
      expect(
        tester.state(find.byType(MonitorScreen, skipOffstage: false)),
        same(state),
      );
    },
  );
}
