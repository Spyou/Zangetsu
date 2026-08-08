import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('committed cheerio bundle parses HTML in QuickJS', () async {
    final bundle = await rootBundle.loadString('assets/js/lnreader_cheerio.js');
    final rt = getJavascriptRuntime(xhr: false);
    expect(rt.evaluate(bundle).isError, isFalse);
    final r = rt.evaluate(
      "var \$=loadCheerio('<a class=x href=/1>Hi</a>'); \$('.x').text()+'|'+\$('.x').attr('href');",
    );
    expect(r.stringResult, 'Hi|/1');
  });
}
