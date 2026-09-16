import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import './host.mjs';

// host.mjs says it is a pure-Node mirror of kJsBootstrap, and the provider
// tests lean on that: a helper that behaves differently here than it does in
// QuickJS makes a green harness run mean nothing. So read the real bootstrap
// out of js_bootstrap.dart, evaluate it into its own bag, and compare the
// helpers that are supposed to be identical on both sides.
//
// Only the pure ones. __fetch / __console / sha256Hex / aesCtrDecrypt are
// deliberately different here (real fetch, node:crypto) instead of hopping the
// Dart bridge, and base64ToBytes disagrees on base64url input, which is its own
// question rather than harness drift.
const OPEN = "r'''";
const CLOSE = '\n' + "'''" + ';';

function loadBootstrapHelpers() {
  const dart = fs.readFileSync(
    new URL('../lib/core/provider/js_bootstrap.dart', import.meta.url), 'utf8');
  const start = dart.indexOf(OPEN, dart.indexOf('kJsBootstrap'));
  const end = dart.indexOf(CLOSE, start);
  assert.ok(start > 0 && end > start, 'could not find the kJsBootstrap string literal');
  const bag = {};
  globalThis.__BOOTSTRAP__ = bag;
  // The bootstrap hangs everything off globalThis; point that at the bag so it
  // cannot stamp over the harness's own copies of the same names.
  (0, eval)(dart.slice(start + OPEN.length, end).replace(/globalThis/g, '__BOOTSTRAP__'));
  assert.equal(typeof bag.htmlText, 'function', 'bootstrap did not define htmlText');
  return bag;
}

const app = loadBootstrapHelpers();

const CASES = {
  htmlText: [
    ['<p>Naruto &#8212; the ninja</p>'],
    ['<p>A &#x2014; B</p>'],
    ['first line\n\n   second line'],
    ['<b>plain</b> &amp; simple'],
    ['&#39;quoted&#39; &nbsp;&lt;tag&gt;'],
    [''],
    [null],
  ],
  absUrl: [
    ['https://a.test/x', 'https://b.test/'],
    ['//cdn.test/x.mp4', 'https://b.test/'],
    ['/ep/1', 'https://b.test/anime'],
    ['/ep/1', 'HTTPS://B.TEST/anime'],
    ['/ep/1', '//cdn.test/anime'],
    ['/ep/1', 'cdn.test/anime'],
    ['ep/1', 'https://b.test/anime/'],
    ['ep/1', null],
    ['', 'https://b.test/'],
    [null, 'https://b.test/'],
  ],
  unpackJs: [
    ['player.src("x")'],
    ["eval(function(p,a,c,k,e,d){}('0 1',2,2,'hello|world'.split('|'),0,{}))"],
    ["eval(function(p,a,c,k,e,d){}('z.10(A)',36,37,'|||||||||||||||||||||||||||||||||||player|src'.split('|'),0,{}))"],
  ],
  bytesToHex: [[[]], [[0, 1, 2, 255]], [[16, 255]]],
  bytesToB64: [[[]], [[0, 1, 2]], [[104, 105]], [[255, 255, 255, 255]]],
  base64ToBytes: [[''], ['AAEC'], ['aGVsbG8='], ['aGVsbG8'], ['AA==']],
};

const show = (args) => args.map((a) => JSON.stringify(a)).join(', ');
const call = (fn, args) => {
  try { return { value: fn(...args) }; }
  catch (e) { return { threw: e.constructor.name + ': ' + e.message }; }
};

for (const [name, inputs] of Object.entries(CASES)) {
  test(`${name} matches kJsBootstrap`, () => {
    assert.equal(typeof globalThis[name], 'function', `harness is missing ${name}`);
    for (const args of inputs) {
      const mine = call(globalThis[name], args);
      const theirs = call(app[name], args);
      assert.deepEqual(mine, theirs,
        `${name}(${show(args)}) differs: harness ${JSON.stringify(mine)} vs app ${JSON.stringify(theirs)}`);
    }
  });
}
