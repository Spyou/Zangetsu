import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadProvider, callProvider } from './host.mjs';

loadProvider('allanime', new URL('../providers/allanime.js', import.meta.url));

const LIVE = process.env.RUN_LIVE === '1';
const live = (name, fn) => test(name, { skip: LIVE ? false : 'set RUN_LIVE=1 to run network test' }, fn);

test('getInfo reports an anime provider', async () => {
  const info = JSON.parse(await callProvider('allanime', 'getInfo', []));
  assert.equal(info.type, 'anime');
  assert.equal(info.name, 'AllAnime');
});

live('search returns results for "one piece"', async () => {
  const rows = JSON.parse(await callProvider('allanime', 'search', ['one piece', 1, {}]));
  assert.ok(Array.isArray(rows) && rows.length > 0, 'expected results');
  assert.ok(rows[0].id && rows[0].title && rows[0].url);
  assert.equal(rows[0].type, 'anime');
});

live('getEpisodes returns a non-empty list for the first result', async () => {
  const rows = JSON.parse(await callProvider('allanime', 'search', ['one piece', 1, {}]));
  const eps = JSON.parse(await callProvider('allanime', 'getEpisodes', [rows[0].url]));
  assert.ok(Array.isArray(eps) && eps.length > 0, 'expected episodes');
});

test('decodeSourceUrl maps the hex-substitution table', async () => {
  const dec = globalThis.__allanimeDecodeSourceUrl;
  assert.equal(typeof dec, 'function', 'decoder hook missing');
  assert.equal(dec('--175948514e4c4f57'), '/apivtwo');
  assert.equal(dec('--175b54575b53'), '/clock.json');
  assert.equal(dec('https://x/y.m3u8'), 'https://x/y.m3u8');
});

live('getVideoSources returns a playable stream for One Piece ep 1', async () => {
  const rows = JSON.parse(await callProvider('allanime', 'search', ['one piece', 1, {}]));
  const detail = JSON.parse(await callProvider('allanime', 'getDetail', [rows[0].url]));
  const ep1 = detail.episodes.find(function (e) { return e.number === 1; }) || detail.episodes[0];
  const sources = JSON.parse(await callProvider('allanime', 'getVideoSources', [ep1.url]));
  assert.ok(sources.length > 0, 'expected sources');
  assert.ok(sources.some(function (s) { return /\.m3u8|\.mp4|fast4speed|wixmp/.test(s.url); }), 'expected a playable url');
  assert.ok(sources.every(function (s) { return s.headers && s.headers.Referer; }), 'headers present');
});

import { loadExtractor as _loadEx } from './host.mjs';
_loadEx(new URL('../extractors/okru.js', import.meta.url));

test('allanime + okru extractor both expose their hooks (wiring present)', () => {
  assert.equal(typeof globalThis.__allanimeDecodeSourceUrl, 'function');
  assert.equal(typeof globalThis.__okruParse, 'function');
});
