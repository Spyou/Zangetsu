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

// Offline dub URL/id scheme test — stubs __fetch to return a fake show response
test('getDetail with category:dub builds /dub/ URLs and dub: ids', async () => {
  const fakeShow = {
    _id: 'test-show-id', name: 'Test Show', englishName: 'Test Show EN',
    thumbnail: null, description: '', availableEpisodes: { sub: 2, dub: 1 },
    availableEpisodesDetail: { sub: ['1', '2'], dub: ['1'] }
  };
  const fakeResponse = {
    ok: true, status: 200, statusText: 'OK', headers: {}, url: '',
    body: JSON.stringify({ data: { show: fakeShow } }),
    text: async () => JSON.stringify({ data: { show: fakeShow } }),
    json: async () => ({ data: { show: fakeShow } }),
  };
  const realFetch = globalThis.__fetch;
  globalThis.__fetch = async (_src, _url, _opts) => fakeResponse;
  try {
    const detail = JSON.parse(await callProvider('allanime', 'getDetail', ['test-show-id', { category: 'dub' }]));
    assert.ok(Array.isArray(detail.episodes), 'episodes must be an array');
    assert.equal(detail.episodes.length, 1, 'dub has 1 episode');
    assert.ok(detail.episodes[0].url.includes('/dub/'), 'url must contain /dub/');
    assert.ok(detail.episodes[0].id.startsWith('dub:'), 'id must start with dub:');
    assert.equal(detail.subCount, 2, 'subCount from availableEpisodes');
    assert.equal(detail.dubCount, 1, 'dubCount from availableEpisodes');
  } finally {
    globalThis.__fetch = realFetch;
  }
});

// Offline sub default — same stub, no opts
test('getDetail without opts defaults to sub and builds /sub/ URLs', async () => {
  const fakeShow = {
    _id: 'test-show-id', name: 'Test Show', englishName: null,
    thumbnail: null, description: '', availableEpisodes: { sub: 2, dub: 1 },
    availableEpisodesDetail: { sub: ['1', '2'], dub: ['1'] }
  };
  const fakeResponse = {
    ok: true, status: 200, statusText: 'OK', headers: {}, url: '',
    body: JSON.stringify({ data: { show: fakeShow } }),
    text: async () => JSON.stringify({ data: { show: fakeShow } }),
    json: async () => ({ data: { show: fakeShow } }),
  };
  const realFetch = globalThis.__fetch;
  globalThis.__fetch = async (_src, _url, _opts) => fakeResponse;
  try {
    const detail = JSON.parse(await callProvider('allanime', 'getDetail', ['test-show-id']));
    assert.ok(Array.isArray(detail.episodes), 'episodes must be an array');
    assert.equal(detail.episodes.length, 2, 'sub has 2 episodes');
    assert.ok(detail.episodes.every(e => e.url.includes('/sub/')), 'all urls must contain /sub/');
    assert.ok(detail.episodes.every(e => e.id.startsWith('sub:')), 'all ids must start with sub:');
  } finally {
    globalThis.__fetch = realFetch;
  }
});

live('getHome returns named sections', async () => {
  const sections = JSON.parse(await callProvider('allanime', 'getHome', [{}]));
  assert.ok(Array.isArray(sections) && sections.length >= 1, 'expected sections');
  assert.ok(
    sections.every((s) => typeof s.title === 'string' && Array.isArray(s.items)),
    'each section is {title, items[]}');
  assert.ok(sections.some((s) => s.items.length > 0), 'at least one row has items');
});

live('popular returns a non-empty list with expected shape', async () => {
  const rows = JSON.parse(await callProvider('allanime', 'popular', [{ dateRange: 7 }]));
  assert.ok(Array.isArray(rows) && rows.length > 0, 'expected popular results');
  for (const row of rows) {
    assert.ok(row.id && row.id.length > 0, 'each item must have a non-empty id');
    assert.ok(row.title && row.title.length > 0, 'each item must have a non-empty title');
    assert.equal(typeof row.subCount, 'number', 'subCount must be a number');
  }
});

import { loadExtractor as _loadEx } from './host.mjs';
_loadEx(new URL('../extractors/okru.js', import.meta.url));

test('allanime + okru extractor both expose their hooks (wiring present)', () => {
  assert.equal(typeof globalThis.__allanimeDecodeSourceUrl, 'function');
  assert.equal(typeof globalThis.__okruParse, 'function');
});

test('settleWithDeadline returns resolved jobs without waiting for hung ones', async () => {
  const settle = globalThis.__allanimeSettleWithDeadline;
  assert.equal(typeof settle, 'function');
  const fast = Promise.resolve([{ url: 'a' }]);
  const hung = new Promise(() => {}); // never resolves
  const t0 = Date.now();
  const out = await settle([fast, hung], 150);
  const dt = Date.now() - t0;
  assert.deepEqual(out, [{ url: 'a' }]);
  assert.ok(dt < 1000, 'should resolve at the ~150ms deadline, not wait for hung');
});
