// AllAnime provider — https://allanime.to (API: https://api.allanime.day/api)
// Sources are AES-encrypted; getVideoSources is added in the next task.

var API = 'https://api.allanime.day/api';
var REFERER = 'https://youtu-chan.com';
var ORIGIN = 'https://youtu-chan.com';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:150.0) Gecko/20100101 Firefox/150.0';
var SOURCE_ID = 'allanime';

var SEARCH_GQL = 'query( $search: SearchInput $limit: Int $page: Int $translationType: VaildTranslationTypeEnumType $countryOrigin: VaildCountryOriginEnumType ) { shows( search: $search limit: $limit page: $page translationType: $translationType countryOrigin: $countryOrigin ) { edges { _id name thumbnail availableEpisodes __typename } }}';
var SHOW_GQL = 'query ($showId: String!) { show( _id: $showId ) { _id name thumbnail description availableEpisodesDetail }}';

function _headers() { return { 'Referer': REFERER, 'Origin': ORIGIN, 'User-Agent': UA, 'Content-Type': 'application/json' }; }

function _post(query, variables) {
  return fetch(API, { method: 'POST', headers: _headers(), body: JSON.stringify({ variables: variables, query: query }) })
    .then(function (r) {
      if (!r.ok) throw new Error('AllAnime: HTTP ' + r.status);
      try { return JSON.parse(r.body || 'null'); } catch (e) { throw new Error('AllAnime: bad JSON (' + r.status + ')'); }
    });
}

function getInfo() {
  return { name: 'AllAnime', lang: 'en', baseUrl: 'https://allanime.to', logo: 'https://allanime.to/favicon.ico', type: 'anime', version: '1.0.0' };
}

function _mode(opts) { var m = (opts && opts.category) || 'sub'; return (m === 'dub') ? 'dub' : 'sub'; }

function search(query, page, opts) {
  var vars = { search: { allowAdult: false, allowUnknown: false, query: String(query || '') }, limit: 26, page: page || 1, translationType: _mode(opts), countryOrigin: 'ALL' };
  return _post(SEARCH_GQL, vars).then(function (j) {
    var edges = (j && j.data && j.data.shows && j.data.shows.edges) || [];
    var out = [];
    for (var i = 0; i < edges.length; i++) {
      var e = edges[i];
      out.push({ id: e._id, title: e.name, cover: e.thumbnail || null, url: e._id, type: 'anime', sourceId: SOURCE_ID });
    }
    return out;
  });
}

function _episodesFromDetail(detailNode) {
  var d = (detailNode && detailNode.availableEpisodesDetail) || {};
  var sub = (d.sub || []).slice();
  var dub = (d.dub || []).slice();
  var nums = {};
  sub.forEach(function (n) { nums[n] = true; });
  dub.forEach(function (n) { nums[n] = true; });
  var keys = Object.keys(nums).sort(function (a, b) { return parseFloat(a) - parseFloat(b); });
  var eps = [];
  for (var i = 0; i < keys.length; i++) {
    var n = keys[i];
    eps.push({ id: n, title: 'Episode ' + n, number: parseFloat(n), url: 'ep://' + n });
  }
  return eps;
}

function getDetail(url) {
  var showId = String(url);
  return _post(SHOW_GQL, { showId: showId }).then(function (j) {
    var show = (j && j.data && j.data.show) || {};
    return {
      id: showId, title: show.name || showId, cover: show.thumbnail || null,
      url: showId, description: show.description || '', status: 'unknown',
      genres: [], studios: [], type: 'anime', sourceId: SOURCE_ID,
      episodes: _episodesFromDetail(show)
    };
  });
}

function getEpisodes(url) {
  return getDetail(url).then(function (d) { return d.episodes; });
}
