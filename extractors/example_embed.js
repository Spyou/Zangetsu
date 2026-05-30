// Deterministic example extractor for the fake host `embed.test`. Performs
// a pure URL transform (no network) so the contract test stays offline.

function getInfo() {
  return { id: 'example_embed', name: 'Example Embed', version: '1.0.0',
           hosts: ['embed.test'] };
}

function extract(url, opts) {
  opts = opts || {};
  var headers = opts.headers || { Referer: 'https://example.test/' };
  var id = url.split('/').pop();
  return [{
    url: 'https://cdn.test/' + id + '/master.m3u8',
    quality: '1080p', container: 'hls', headers: headers,
    kind: 'sub', audioLang: 'ja',
    subtitles: [
      { url: 'https://cdn.test/' + id + '/en.vtt', lang: 'en',
        label: 'English', format: 'vtt', default: true },
    ],
  }];
}
