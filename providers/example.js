// Deterministic, offline example provider. Proves the contract + the
// extractVideo dispatch path end-to-end without hitting the network.

var SOURCE_ID = 'example';
var SITE = 'https://example.test';
var REFERER = SITE + '/';

function getInfo() {
  return { name: 'Example Anime', lang: 'en', baseUrl: SITE,
           logo: SITE + '/logo.png', type: 'anime', version: '1.0.0' };
}

function _catalog() {
  return [{
    id: 'one-piece', title: 'One Piece',
    cover: SITE + '/op.jpg', coverHeaders: { Referer: REFERER },
    url: SITE + '/anime/one-piece', type: 'anime', sourceId: SOURCE_ID,
  }];
}

function search(query, page, opts) {
  var q = String(query || '').toLowerCase();
  return _catalog().filter(function (m) {
    return q === '' || m.title.toLowerCase().indexOf(q) !== -1;
  });
}

function _episodes() {
  return [
    { id: 'ep-1', title: 'Episode 1', number: 1,
      url: SITE + '/watch/one-piece/1', date: '1999-10-20' },
    { id: 'ep-2', title: 'Episode 2', number: 2,
      url: SITE + '/watch/one-piece/2', date: '1999-10-27' },
  ];
}

function getDetail(url) {
  return {
    id: 'one-piece', title: 'One Piece', url: url,
    cover: SITE + '/op.jpg', coverHeaders: { Referer: REFERER },
    description: 'A pirate adventure.', status: 'ongoing',
    genres: ['Action', 'Adventure'], studios: ['Toei Animation'],
    type: 'anime', sourceId: SOURCE_ID, episodes: _episodes(),
  };
}

function getEpisodes(seriesUrl) {
  return _episodes();
}

function getVideoSources(episodeUrl) {
  // Return an embed and let the shared extractor resolve it — this is the
  // path real providers use.
  var id = episodeUrl.split('/').pop();
  return extractVideo('https://embed.test/e/' + id,
                      { headers: { Referer: REFERER } });
}
