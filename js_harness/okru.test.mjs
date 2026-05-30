import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadExtractor } from './host.mjs';
loadExtractor(new URL('../extractors/okru.js', import.meta.url));

const LIVE = process.env.RUN_LIVE === '1';
const live = (n, f) => test(n, { skip: LIVE ? false : 'set RUN_LIVE=1' }, f);

test('okru parses data-options → mp4 + hls', () => {
  const meta = JSON.stringify({
    videos: [{ name: 'hd', url: 'https://cdn.okcdn.ru/v720.mp4' },
             { name: 'sd', url: 'https://cdn.okcdn.ru/v480.mp4' }],
    hlsManifestUrl: 'https://cdn.okcdn.ru/master.m3u8',
  });
  const opts = JSON.stringify({ flashvars: { metadata: meta } });
  const html = `<div data-module="OKVideo" data-options="${opts.replace(/"/g, '&quot;')}"></div>`;
  const out = globalThis.__okruParse(html, { 'User-Agent': 'X' });
  assert.ok(out.some(s => s.container === 'hls' && /master\.m3u8/.test(s.url)));
  const hd = out.find(s => s.quality === '720p');
  assert.equal(hd.url, 'https://cdn.okcdn.ru/v720.mp4');
  assert.equal(hd.container, 'mp4');
  assert.equal(hd.headers['User-Agent'], 'X');
});

live('okru live extract returns a playable source', async () => {
  const out = await globalThis.extractVideo('https://ok.ru/videoembed/26870090463', {});
  assert.ok(out.length > 0 && out.every(s => /^https?:\/\//.test(s.url)));
});
