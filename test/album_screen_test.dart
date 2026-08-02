import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sony_transfer/screens/album_screen.dart';
import 'package:sony_transfer/services/transfer_service.dart';

/// A 1x1 transparent PNG. Real bytes (rather than junk) so `Image.file`
/// decodes successfully instead of exercising the error-builder path.
final List<int> _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
  'AAAAASUVORK5CYII=',
);

/// [AlbumScreen] does real (if tiny) disk I/O and image decoding to load
/// itself, none of which is driven by [WidgetTester.pump]'s fake clock —
/// [WidgetTester.runAsync] steps out to the real event loop so that work
/// actually gets a chance to run and complete. Every real `dart:io` call in
/// these tests, including [setUp]/[writePhoto], needs the same treatment, or
/// it hangs forever instead of erroring.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sony_transfer_album_test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> writePhoto(
    WidgetTester tester,
    String name, {
    required DateTime modifiedAt,
  }) =>
      tester.runAsync(() async {
        final file = File('${temp.path}/$name');
        await file.writeAsBytes(_onePixelPng);
        await file.setLastModified(modifiedAt);
      });

  Widget appWith(TransferService service, {VoidCallback? onOpenTransfer}) =>
      MaterialApp(
        home: AlbumScreen(
          transferService: service,
          onOpenTransfer: onOpenTransfer ?? () {},
        ),
      );

  testWidgets('shows an empty state with a way to connect the camera',
      (tester) async {
    await tester.pumpWidget(appWith(TransferService(destination: temp)));
    await _settle(tester);

    expect(find.text('No photos transferred yet'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Connect camera'),
      findsOneWidget,
    );
  });

  testWidgets('lists already-transferred shots grouped by day, newest first',
      (tester) async {
    final today = DateTime.now();
    final yesterday = today.subtract(const Duration(days: 1));

    await writePhoto(tester, 'A.JPG', modifiedAt: yesterday);
    await writePhoto(tester, 'B.JPG', modifiedAt: today);
    // An interrupted download's leftover — should never be counted.
    await writePhoto(tester, 'C.JPG.part', modifiedAt: today);

    await tester.pumpWidget(appWith(TransferService(destination: temp)));
    await _settle(tester);

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('2 transferred'), findsOneWidget);

    // "Today" (B.JPG) should come before "Yesterday" (A.JPG) — newest first.
    final todayY = tester.getTopLeft(find.text('Today')).dy;
    final yesterdayY = tester.getTopLeft(find.text('Yesterday')).dy;
    expect(todayY, lessThan(yesterdayY));
  });

  testWidgets('tapping a shot opens the full-screen swipe preview',
      (tester) async {
    await writePhoto(tester, 'A.JPG', modifiedAt: DateTime.now());

    await tester.pumpWidget(appWith(TransferService(destination: temp)));
    await _settle(tester);

    await tester.tap(find.byType(Image).first);
    await _settle(tester);

    expect(find.text('1 / 1'), findsOneWidget);
    expect(find.text('A.JPG'), findsOneWidget);
  });

  testWidgets('the preview info button shows the shot details',
      (tester) async {
    await writePhoto(tester, 'A.JPG', modifiedAt: DateTime(2026, 7, 30, 12));

    await tester.pumpWidget(appWith(TransferService(destination: temp)));
    await _settle(tester);

    await tester.tap(find.byType(Image).first);
    await _settle(tester);
    // Let the route transition finish, or the app bar is still sliding in
    // from off-screen and the info button cannot be hit.
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byTooltip('Photo info'));
    // The sheet's own slide-up animation, then the real file/EXIF reads.
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);

    expect(find.text('Size'), findsOneWidget);
    // The 1x1 PNG fixture's real dimensions, read from the image header.
    expect(find.text('1 × 1 (0.0 MP)'), findsOneWidget);
    // No EXIF in the fixture, so the shot date falls back to the file's
    // stamped modification time.
    expect(find.text('2026-07-30 12:00:00'), findsOneWidget);
    expect(find.text('Path'), findsOneWidget);
    expect(find.textContaining('A.JPG'), findsWidgets);
    // ...and a detail the fixture simply does not carry stays hidden.
    expect(find.text('Focal length'), findsNothing);
  });

  testWidgets(
      'long-press selects, and delete (after confirming) removes the shot '
      'from the album', (tester) async {
    await writePhoto(tester, 'A.JPG', modifiedAt: DateTime.now());

    await tester.pumpWidget(appWith(TransferService(destination: temp)));
    await _settle(tester);

    await tester.longPress(find.byType(Image).first);
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete'));
    await _settle(tester);
    // Destructive, so a confirmation dialog stands in the way.
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await _settle(tester);

    expect(find.text('No photos transferred yet'), findsOneWidget);
    await tester.runAsync(() async {
      expect(File('${temp.path}/A.JPG').existsSync(), isFalse);
    });
  });

  testWidgets('cancelling selection returns to the normal album',
      (tester) async {
    await writePhoto(tester, 'A.JPG', modifiedAt: DateTime.now());

    await tester.pumpWidget(appWith(TransferService(destination: temp)));
    await _settle(tester);

    await tester.longPress(find.byType(Image).first);
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Cancel selection'));
    await tester.pump();
    expect(find.text('1 selected'), findsNothing);
    expect(find.byTooltip('Connect camera'), findsOneWidget);
  });

  testWidgets(
      'the connect camera action hands off to the shell rather than pushing '
      'a route of its own', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      appWith(TransferService(destination: temp), onOpenTransfer: () => opened++),
    );
    await _settle(tester);

    await tester.tap(find.byTooltip('Connect camera'));
    expect(opened, 1);
  });
}
