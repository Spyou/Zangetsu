import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadProvider, callProvider } from './host.mjs';

loadProvider('netmirror', new URL('../providers/netmirror.js', import.meta.url));

const LIVE = process.env.RUN_LIVE === '1';
const live = (name, fn) => test(name, { skip: LIVE ? false : 'set RUN_LIVE=1 to run network test' }, fn);

// --- Offline ---------------------------------------------------------------
test('getInfo reports the NetMirror movie provider', async () => {
  const info = JSON.parse(await callProvider('netmirror', 'getInfo', []));
  assert.equal(info.name, 'NetMirror');
  assert.equal(info.type, 'movie');
  assert.equal(info.lang, 'en');
});

// --- Live: full chain search -> detail -> m3u8 -----------------------------
live('search returns results for "stranger"', async () => {
  const rows = JSON.parse(await callProvider('netmirror', 'search', ['stranger', 1, {}]));
  assert.ok(Array.isArray(rows) && rows.length > 0, 'expected search results');
  for (const row of rows) {
    assert.ok(row.id && row.id.length > 0, 'each item must have an id');
    assert.ok(typeof row.title === 'string', 'each item must have a title field');
  }
});

live('getDetail returns a title and an episodes array', async () => {
  const rows = JSON.parse(await callProvider('netmirror', 'search', ['stranger', 1, {}]));
  const detail = JSON.parse(await callProvider('netmirror', 'getDetail', [rows[0].id, {}]));
  assert.ok(detail.title && detail.title.length > 0, 'expected a title');
  assert.ok(Array.isArray(detail.episodes), 'expected episodes array');
  assert.ok(detail.episodes.length > 0, 'expected at least one episode');
});

live('getVideoSources returns an HLS .m3u8 stream', async () => {
  const rows = JSON.parse(await callProvider('netmirror', 'search', ['stranger', 1, {}]));
  const detail = JSON.parse(await callProvider('netmirror', 'getDetail', [rows[0].id, {}]));
  const epUrl = (detail.episodes[0] && detail.episodes[0].url) || rows[0].id;
  const sources = JSON.parse(await callProvider('netmirror', 'getVideoSources', [epUrl]));
  assert.ok(Array.isArray(sources) && sources.length >= 1, 'expected sources');
  assert.ok(/\.m3u8/.test(sources[0].url), 'expected a .m3u8 url, got ' + sources[0].url);
  assert.equal(sources[0].container, 'hls');
  console.log('[netmirror] resolved stream:', sources[0].url);
});
