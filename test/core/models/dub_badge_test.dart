import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/search_quality.dart';

// CloudStream reports an anime listing's DubStatus as a set. `None` is its
// "not applicable" member rather than a real state, so a source that only
// sends that has told us nothing and must not get a badge.
void main() {
  test('both statuses read as one badge', () {
    expect(dubBadgeLabel(['Dubbed', 'Subbed']), 'SUB DUB');
  });

  test('a single status reads as itself', () {
    expect(dubBadgeLabel(['Subbed']), 'SUB');
    expect(dubBadgeLabel(['Dubbed']), 'DUB');
  });

  test('nothing to say means no badge', () {
    expect(dubBadgeLabel(null), isNull);
    expect(dubBadgeLabel([]), isNull);
    expect(dubBadgeLabel(['None']), isNull);
  });

  test('an unknown value is ignored rather than shown raw', () {
    expect(dubBadgeLabel(['Whatever']), isNull);
    expect(dubBadgeLabel(['Whatever', 'Subbed']), 'SUB');
  });
}
