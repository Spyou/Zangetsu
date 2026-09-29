import { test } from 'node:test';
import assert from 'node:assert/strict';
import './host.mjs';

test('unpackJs decodes a Dean-Edwards packed string', () => {
  const packed = "eval(function(p,a,c,k,e,d){e=function(c){return c};if(!''.replace(/^/,String)){while(c--){d[c]=k[c]||c}k=[function(e){return d[e]}];e=function(){return'\\\\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\\\\b'+e(c)+'\\\\b','g'),k[c])}}return p}('0 1',2,2,'hello|world'.split('|'),0,{}))";
  assert.equal(globalThis.unpackJs(packed), 'hello world');
});

test('unpackJs returns input unchanged when not packed', () => {
  assert.equal(globalThis.unpackJs('player.src("x")'), 'player.src("x")');
});

// Packs `src` the way the packer does, in base `radix`, with enough distinct
// words that some of them need two digits. The 36-and-under form is the short
// `c.toString(a)` one that embed pages commonly serve; 62 needs the long one.
function pack(src, radix) {
  const words = [...new Set(src.match(/\b\w+\b/g))];
  const enc = radix <= 36
    ? (n) => n.toString(radix)
    : (n) => (n < radix ? '' : enc(Math.floor(n / radix))) +
        ((n = n % radix) > 35 ? String.fromCharCode(n + 29) : n.toString(36));
  const payload = src.replace(/\b\w+\b/g, (w) => enc(words.indexOf(w)));
  const fn = radix <= 36
    ? "function(p,a,c,k,e,d){while(c--)if(k[c])p=p.replace(new RegExp('\\\\b'+c.toString(a)+'\\\\b','g'),k[c]);return p}"
    : "function(p,a,c,k,e,d){e=function(c){return(c<a?'':e(parseInt(c/a)))+((c=c%a)>35?String.fromCharCode(c+29):c.toString(36))};while(c--)if(k[c])p=p.replace(new RegExp('\\\\b'+e(c)+'\\\\b','g'),k[c]);return p}";
  return 'eval(' + fn + "('" + payload + "'," + radix + ',' + words.length +
    ",'" + words.join('|') + "'.split('|'),0,{}))";
}

// What the page itself gets when the browser runs the packed script.
function evaluated(packed) {
  let out;
  new Function('eval', packed)((s) => { out = s; });
  return out;
}

const names = Array.from({ length: 70 }, (_, i) => 'v' + String.fromCharCode(97 + (i % 26)) + i);
const script = 'var ' + names.join('=null;var ') +
  '=null;player.src("https://host.example/video.mp4")';

for (const radix of [10, 36, 62]) {
  test(`unpackJs decodes a script packed in base ${radix}`, () => {
    const packed = pack(script, radix);
    assert.equal(evaluated(packed), script);
    assert.equal(globalThis.unpackJs(packed), script);
  });
}
