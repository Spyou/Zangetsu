import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadExtractor } from './host.mjs';
loadExtractor(new URL('../extractors/doodstream.js', import.meta.url));

const LIVE = process.env.RUN_LIVE === '1';
const live = (n, f) => test(n, { skip: LIVE ? false : 'set RUN_LIVE=1' }, f);

test('doodstream builds final url from page + pass body', () => {
  const host = 'https://dood.li';
  const pageHtml = "<script>$.get('/pass_md5/abc/deftoken', function(d){})</script>";
  const passBody = 'https://cdn.dood.example/video/';
  const s = globalThis.__doodBuild(host, pageHtml, passBody, host + '/e/xyz');
  assert.equal(s.container, 'mp4');
  assert.match(s.url, /^https:\/\/cdn\.dood\.example\/video\/[A-Za-z0-9]{10}\?token=deftoken&expiry=\d+$/);
  assert.equal(s.headers.Referer, 'https://dood.li/');
});

live('doodstream live tolerated', async () => {
  const out = await globalThis.extractVideo('https://dood.li/e/0000000000', {}).catch(() => []);
  assert.ok(Array.isArray(out));
});
