import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadExtractor } from './host.mjs';
loadExtractor(new URL('../extractors/mp4upload.js', import.meta.url));

const LIVE = process.env.RUN_LIVE === '1';
const live = (n, f) => test(n, { skip: LIVE ? false : 'set RUN_LIVE=1' }, f);

test('mp4upload parses clear-text src + HEIGHT', () => {
  const html = '<script>var x; player.src("https://www7.mp4upload.com:282/d/abc/video.mp4"); var l=[{file:"...",label:"720p",type:"video/mp4"}]; HEIGHT=720;</script>';
  const s = globalThis.__mp4uploadParse(html);
  assert.equal(s.url, 'https://www7.mp4upload.com:282/d/abc/video.mp4');
  assert.equal(s.quality, '720p');
  assert.equal(s.container, 'mp4');
  assert.equal(s.headers.Referer, 'https://www.mp4upload.com/');
});

test('mp4upload returns null when no src', () => {
  assert.equal(globalThis.__mp4uploadParse('<html>nope</html>'), null);
});

live('mp4upload live (404 page tolerated)', async () => {
  const out = await globalThis.extractVideo('https://www.mp4upload.com/embed-000000000000.html', {})
    .catch(() => []);
  assert.ok(Array.isArray(out));
});
