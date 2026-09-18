import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadProvider, callProvider } from './host.mjs';

// One file, loaded once per OTT platform under a distinct sourceId. The
// platform (ott / path prefix / poster path) is derived from __SOURCE_ID.
const NM = new URL('../providers/netmirror.js', import.meta.url);
loadProvider('netmirror_nf', NM);
loadProvider('netmirror_pv', NM);

const LIVE = process.env.RUN_LIVE === '1';
const live = (name, fn) => test(name, { skip: LIVE ? false : 'set RUN_LIVE=1 to run network test' }, fn);

// --- Offline ---------------------------------------------------------------
test('platform name derives from sourceId', async () => {
  const nf = JSON.parse(await callProvider('netmirror_nf', 'getInfo', []));
  const pv = JSON.parse(await callProvider('netmirror_pv', 'getInfo', []));
  assert.equal(nf.name, 'Netflix');
  assert.equal(pv.name, 'Prime Video');
  assert.equal(nf.type, 'movie');
});

// --- Live: getHome returns the provider's own distinct named rows ----------
live('netflix: getHome returns named sections', async () => {
  const sections = JSON.parse(await callProvider('netmirror_nf', 'getHome', [{}]));
  assert.ok(Array.isArray(sections) && sections.length >= 1, 'expected sections');
  assert.ok(
    sections.every((s) => typeof s.title === 'string' && Array.isArray(s.items)),
    'each section is {title, items[]}');
  console.log('[netmirror nf] home rows:', sections.map((s) => s.title + ':' + s.items.length));
});

// --- Live: Netflix full chain search -> detail -> PLAYABLE master ----------
// Asserts the resolved url is not just a .m3u8 but a master that actually
// contains video (#EXT-X-STREAM-INF) reachable with the source's own headers.
live('netflix: search -> detail -> playable master (has video)', async () => {
  const rows = JSON.parse(await callProvider('netmirror_nf', 'search', ['stranger', 1, {}]));
  assert.ok(Array.isArray(rows) && rows.length > 0, 'expected search results');
  const detail = JSON.parse(await callProvider('netmirror_nf', 'getDetail', [rows[0].id, {}]));
  assert.ok(detail.title && detail.title.length > 0, 'expected a title');
  assert.ok(Array.isArray(detail.episodes) && detail.episodes.length > 0, 'expected episodes');
  const epUrl = detail.episodes[0].url || rows[0].id;
  const sources = JSON.parse(await callProvider('netmirror_nf', 'getVideoSources', [epUrl]));
  assert.ok(Array.isArray(sources) && sources.length >= 1, 'expected sources');
  assert.ok(/\.m3u8/.test(sources[0].url), 'expected .m3u8, got ' + sources[0].url);
  assert.equal(sources[0].container, 'hls');
  // The returned url must point to a master with real video variants.
  const m3u8 = await (await fetch(sources[0].url, { headers: sources[0].headers })).text();
  assert.ok(/#EXT-X-STREAM-INF/.test(m3u8), 'master should contain video variants, got: ' + m3u8.slice(0, 160));
  assert.ok(!/https:\/\/\/files/.test(m3u8), 'master should not be the broken audio-only stub');
  console.log('[netmirror nf] playable master:', sources[0].url);
});

// --- Live: a non-playable collection id is rejected (not a black screen) ---
live('netflix: series/collection id is rejected with a clear error', async () => {
  const rows = JSON.parse(await callProvider('netmirror_nf', 'search', ['stranger', 1, {}]));
  // rows[0].id is the SERIES id; feeding it directly must NOT yield a stub source.
  await assert.rejects(
    () => callProvider('netmirror_nf', 'getVideoSources', [rows[0].id]),
    /not available|no stream/i,
    'series id should be rejected, not returned as a broken source'
  );
});

// --- Live: Prime is a DISTINCT catalog (per-OTT path prefix works) ---------
live('prime: search returns a distinct catalog', async () => {
  const nf = JSON.parse(await callProvider('netmirror_nf', 'search', ['the', 1, {}]));
  const pv = JSON.parse(await callProvider('netmirror_pv', 'search', ['the', 1, {}]));
  assert.ok(pv.length > 0, 'expected Prime results');
  const nfIds = new Set(nf.map((r) => r.id));
  const overlap = pv.filter((r) => nfIds.has(r.id)).length;
  assert.equal(overlap, 0, 'Netflix and Prime catalogs should not overlap');
  console.log('[netmirror pv] sample:', pv.slice(0, 3).map((r) => r.title));
});

// --- Offline: a browse feed that came back empty is a FAILURE, not a catalog -
// Every seed query is individually tolerant (`_searchRaw` swallows its error
// and yields []), so one cold start without a cookie makes `_browseFeed`
// produce []. Caching that keeps Browse empty for the rest of the session.
test('an empty browse feed is not cached for the session', async () => {
  // Its own sourceId, so this gets its own module closure (and its own
  // _cookie / _browse) instead of whatever the tests above left behind.
  loadProvider('netmirror_hs', NM);
  const real = globalThis.__fetch;
  let online = false;
  globalThis.__fetch = async (_src, url) => {
    if (!online) throw new Error('offline');
    if (url.indexOf('/verify.php') >= 0) {
      return { ok: true, status: 200, url, body: '',
               headers: { 'set-cookie': 't_hash_t=deadbeef; Path=/' } };
    }
    return { ok: true, status: 200, url, headers: {},
             body: JSON.stringify({ searchResult: [
               { id: '101', t: 'One' }, { id: '102', t: 'Two' }, { id: '103', t: 'Three' }] }) };
  };
  try {
    const cold = JSON.parse(await callProvider('netmirror_hs', 'popular', [{ dateRange: 1 }]));
    assert.deepEqual(cold, [], 'nothing reachable yet, so nothing to show');

    online = true;
    const warm = JSON.parse(await callProvider('netmirror_hs', 'popular', [{ dateRange: 1 }]));
    assert.ok(warm.length > 0,
      'browse should come back once the source answers again, got ' + JSON.stringify(warm));
  } finally {
    globalThis.__fetch = real;
  }
});
