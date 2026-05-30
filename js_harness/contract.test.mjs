import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadProvider, callProvider, loadExtractor } from './host.mjs';

loadProvider('example', new URL('../providers/example.js', import.meta.url));
loadExtractor(new URL('../extractors/example_embed.js', import.meta.url));

test('getInfo reports an anime provider', async () => {
  const info = JSON.parse(await callProvider('example', 'getInfo', []));
  assert.equal(info.type, 'anime');
  assert.equal(info.name, 'Example Anime');
});

test('search returns MediaItem rows', async () => {
  const rows = JSON.parse(await callProvider('example', 'search', ['one', 1, {}]));
  assert.ok(Array.isArray(rows) && rows.length > 0);
  assert.equal(rows[0].type, 'anime');
  assert.ok(rows[0].id && rows[0].url && rows[0].title);
});

test('getDetail returns episodes', async () => {
  const detail = JSON.parse(
    await callProvider('example', 'getDetail', ['https://example.test/anime/one-piece']));
  assert.equal(detail.status, 'ongoing');
  assert.ok(detail.episodes.length >= 1);
  assert.equal(detail.episodes[0].id, 'ep-1');
});

test('getEpisodes returns the same episode list shape', async () => {
  const eps = JSON.parse(
    await callProvider('example', 'getEpisodes', ['https://example.test/anime/one-piece']));
  assert.ok(Array.isArray(eps));
  assert.equal(eps[0].number, 1);
});

test('extractVideo resolves an embed host to VideoSources', async () => {
  const sources = await globalThis.extractVideo('https://embed.test/e/1', {
    headers: { Referer: 'https://example.test/' },
  });
  assert.ok(Array.isArray(sources) && sources.length > 0);
  assert.equal(sources[0].container, 'hls');
  assert.equal(sources[0].kind, 'sub');
  assert.match(sources[0].url, /\.m3u8$/);
});

test('provider.getVideoSources flows through extractVideo end-to-end', async () => {
  const sources = JSON.parse(
    await callProvider('example', 'getVideoSources', ['https://example.test/watch/one-piece/1']));
  assert.ok(sources.length > 0);
  assert.equal(sources[0].kind, 'sub');
  assert.equal(sources[0].headers.Referer, 'https://example.test/');
  assert.ok(sources[0].subtitles.length >= 1);
});
