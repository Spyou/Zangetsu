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
