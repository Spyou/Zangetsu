import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/watch_comments_placeholder.dart';

void main() {
  testWidgets('shows a coming-soon message', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: WatchCommentsPlaceholder()),
    ));
    expect(find.text('Comments are coming'), findsOneWidget);
    expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
  });
}
