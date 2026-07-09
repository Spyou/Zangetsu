import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/tv_track_menu.dart';

void main() {
  testWidgets('renders section titles and options', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: TvTrackMenu(
        onClose: () {},
        sections: [
          TvMenuSection(title: 'Quality', options: [
            TvMenuOption(label: 'Auto', selected: true, onSelect: () {}),
            TvMenuOption(label: '1080p', onSelect: () {}),
          ]),
          TvMenuSection(title: 'Audio', options: [
            TvMenuOption(label: 'Japanese', onSelect: () {}),
          ]),
        ],
      ),
    ));
    expect(find.text('Quality'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('Japanese'), findsOneWidget);
  });

  testWidgets('tapping an option fires its callback', (tester) async {
    var picked = '';
    await tester.pumpWidget(MaterialApp(
      home: TvTrackMenu(
        onClose: () {},
        sections: [
          TvMenuSection(title: 'Quality', options: [
            TvMenuOption(label: '1080p', onSelect: () => picked = '1080p'),
          ]),
        ],
      ),
    ));
    await tester.tap(find.text('1080p'));
    await tester.pump();
    expect(picked, '1080p');
  });
}
