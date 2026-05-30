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
