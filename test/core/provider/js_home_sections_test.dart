import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/provider_manager.dart';

void main() {
  const rowItem = {
    'id': 'm1',
    'title': 'Item',
    'url': 'https://x.test/m1',
    'type': 'anime',
  };

  test('a JS home row with an id gets a js_home paging descriptor', () {
    final rows = JsProvider.homeSectionsFromJson([
      {
        'title': 'Paged',
        'id': 'row-a',
        'items': [rowItem],
      },
    ], 'js:1');
    expect(rows, hasLength(1));
    expect(rows.single.more?.kind, 'js_home');
    expect(rows.single.more?.sourceId, 'js:1');
    expect(rows.single.more?.categoryId, 'row-a');
    expect(rows.single.lazyFallback, isFalse);
  });

  test(
    'a JS home row without an id falls back to client-side lazy loading',
    () {
      final rows = JsProvider.homeSectionsFromJson([
        {
          'title': 'Old provider',
          'items': [rowItem],
        },
      ], 'js:2');
      expect(rows.single.more, isNull);
      expect(rows.single.lazyFallback, isTrue);
    },
  );
}
