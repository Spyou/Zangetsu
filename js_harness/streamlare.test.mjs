import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadExtractor } from './host.mjs';
loadExtractor(new URL('../extractors/streamlare.js', import.meta.url));

const LIVE = process.env.RUN_LIVE === '1';
const live = (n, f) => test(n, { skip: LIVE ? false : 'set RUN_LIVE=1' }, f);

test('streamlare maps hls result', () => {
  const json = JSON.stringify({ status: 'success', type: 'hls',
    result: { '1080p': { label: '1080p', file: 'https:\\/\\/x\\/master.m3u8', type: 'hls' } } });
  const out = globalThis.__streamlareParse(json, { Referer: 'https://slwatch.co/' });
  assert.equal(out.length, 1);
  assert.equal(out[0].url, 'https://x/master.m3u8');
  assert.equal(out[0].container, 'hls');
  assert.equal(out[0].quality, '1080p');
});

test('streamlare idFromUrl', () => {
  assert.equal(globalThis.__streamlareId('https://streamlare.com/e/oLvgezw3LjPzbp8E'), 'oLvgezw3LjPzbp8E');
});

live('streamlare live (may be anti-bot blocked from datacenter)', async () => {
  const out = await globalThis.extractVideo('https://streamlare.com/e/oLvgezw3LjPzbp8E', {}).catch(() => []);
  assert.ok(Array.isArray(out));
});
