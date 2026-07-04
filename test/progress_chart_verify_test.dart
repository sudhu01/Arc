import 'dart:io';
import 'dart:ui' as ui;

import 'package:arc/theme/app_theme.dart';
import 'package:arc/widgets/charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ProgressChart: stacked date labels + tap opens value dialog',
      (tester) async {
    final points = [
      ProgressPoint(DateTime(2026, 1, 3), 100),
      ProgressPoint(DateTime(2026, 2, 14), 105),
      ProgressPoint(DateTime(2026, 3, 21), 110),
      ProgressPoint(DateTime(2026, 4, 5), 112),
      ProgressPoint(DateTime(2026, 5, 29), 118),
      ProgressPoint(DateTime(2026, 6, 3), 120),
    ];

    await tester.pumpWidget(MaterialApp(
      theme: buildArcTheme(),
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: RepaintBoundary(
            key: const Key('chart-boundary'),
            child: ProgressChart(points: points, unit: 'kg', height: 150),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Render the chart to a PNG so the stacked "Jun" / "3" x-axis labels can
    // be inspected visually for overlap.
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('chart-boundary')));
    final image = await boundary.toImage(pixelRatio: 3.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final outDir = Directory(
        r'C:\Users\jacks\AppData\Local\Temp\claude\c--Users-jacks-OneDrive-Desktop-Arc\641ae09a-f319-401b-b0f3-ba85bfcb43f2\scratchpad');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final outFile = File('${outDir.path}/progress_chart_before_tap.png');
    await outFile.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('Wrote screenshot: ${outFile.path}');

    // Tap near the most recent (rightmost) session point.
    final chartFinder = find.byType(ProgressChart);
    final topLeft = tester.getTopLeft(chartFinder);
    final size = tester.getSize(chartFinder);
    await tester.tapAt(
        Offset(topLeft.dx + size.width - 10, topLeft.dy + size.height / 2));
    await tester.pumpAndSettle();

    expect(find.textContaining('Jun 3'), findsOneWidget,
        reason: 'dialog should show the tapped session\'s date');
    expect(find.text('120'), findsOneWidget,
        reason: 'dialog should show the tapped session\'s value');
    expect(find.text('kg'), findsWidgets);
    expect(find.text('Close'), findsOneWidget);
  });
}
