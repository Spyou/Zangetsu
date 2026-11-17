import 'package:flutter/material.dart';

import '../../core/models/home_row.dart';

/// Keeps reactive Continue rows as slivers and builds other rows near the viewport.
List<Widget> homeRowsSlivers(
  List<HomeRow> rows, {
  required Widget Function(HomeRow) rowBuilder,
  required Widget Function() continueBuilder,
}) {
  final slivers = <Widget>[];
  var index = 0;
  while (index < rows.length) {
    if (rows[index] is LocalContinueHomeRow) {
      slivers.add(continueBuilder());
      index++;
      continue;
    }
    final start = index;
    while (index < rows.length && rows[index] is! LocalContinueHomeRow) {
      index++;
    }
    final group = rows.sublist(start, index);
    final occurrences = <String, int>{};
    final keys = [
      for (final row in group)
        ValueKey((
          row.id,
          occurrences.update(row.id, (n) => n + 1, ifAbsent: () => 0),
        )),
    ];
    final indices = {for (var i = 0; i < keys.length; i++) keys[i]: i};
    slivers.add(
      SliverList.builder(
        itemCount: group.length,
        findChildIndexCallback: (key) => indices[key],
        itemBuilder: (context, i) =>
            KeyedSubtree(key: keys[i], child: rowBuilder(group[i])),
      ),
    );
  }
  return slivers;
}
