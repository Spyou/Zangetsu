import 'package:flutter_test/flutter_test.dart';

import 'package:watch_app/core/lnreader/lnreader_runtime.dart';

const _fakePlugin = '''
exports.default = {
  name: 'Fake',
  parseNovel: function (path) {
    var fetchApi = require('@libs/fetch').fetchApi;
    return fetchApi('http://x' + path).then(function (r) { return r.text(); }).then(function (html) {
      var \$ = require('cheerio').load(html);
      return { name: \$('h1').text() };
    });
  },
};
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads a plugin and drives a fetch through the outbox bridge', () async {
    final runtime = LnReaderRuntime(
      fetch: (url, init) async => const LnReaderHttpResponse(
        status: 200,
        body: '<h1>Hello</h1>',
        url: 'http://x/a',
      ),
    );

    final name = await runtime.loadPlugin('fake', _fakePlugin);
    expect(name, 'Fake');

    final result = await runtime.call('fake', 'parseNovel', ['/a']);
    expect(result, {'name': 'Hello'});

    runtime.dispose();
  });

  test(
    'a fetch failure rejects the plugin call instead of hanging to the 30s timeout',
    () async {
      final runtime = LnReaderRuntime(
        fetch: (url, init) async =>
            throw Exception('boom: connection refused'),
      );

      await runtime.loadPlugin('fake', _fakePlugin);

      await expectLater(
        runtime.call('fake', 'parseNovel', ['/a']),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('boom: connection refused'),
          ),
        ),
      );

      runtime.dispose();
    },
    // Well under the driver's 30s call timeout: if __rejectFetch ever stops
    // reaching the pending promise, this test times out instead of quietly
    // passing 30s slower.
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
