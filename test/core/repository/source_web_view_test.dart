// The browser is offered per source, and a source with no site to open must
// not offer it — a screen that loads about:blank helps nobody. The URL comes
// from a different field in each ecosystem, so the lookup is worth pinning.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/repository/source_actions.dart' as source_actions;

void main() {
  test('a source with no known site offers no browser', () {
    expect(source_actions.webViewUrlFor('not-a-real-source'), isNull);
  });

  test('the metadata catalogue is not a site you can log in to', () {
    // Z Mode is a catalogue, not a provider with an account.
    expect(source_actions.webViewUrlFor('zm'), isNull);
  });
}
