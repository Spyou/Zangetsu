// NetMirror provider — Netflix / Prime / Hotstar / Disney+ mirror (HLS).
// Host: https://net52.cc. ONE file, loaded once per platform under a distinct
// sourceId (netmirror_nf / _pv / _hs / _dp). The platform is derived from the
// runtime-provided __SOURCE_ID, which selects the ott cookie, the path prefix
// (/mobile, /mobile/pv, /mobile/hs) and the poster CDN path. Verified live.

var MAIN = 'https://net52.cc';
var IMG = 'https://imgcdn.kim';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
// The NewTV player API fingerprints this UA; matching the CloudStream reference
// (Sushan64/NetMirror-Extension Utils.kt `newTvBaseHeaders`) keeps player.php happy.
var NEWTV_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:136.0) Gecko/20100101 Firefox/136.0 /OS.GatuNewTV v1.0';
var NEWTV_DOMAINS = ['https://mobiledetects.com', 'https://mobidetect.art', 'https://mobidetect.cc'];

// --- Platform config from the registered sourceId ---------------------------
var _ID = (typeof __SOURCE_ID !== 'undefined' && __SOURCE_ID) ? String(__SOURCE_ID) : 'netmirror_nf';
function _ottFor(id) {
  if (id.indexOf('_pv') >= 0) return 'pv';
  if (id.indexOf('_dp') >= 0) return 'dp';
  if (id.indexOf('_hs') >= 0) return 'hs';
  return 'nf';
}
var OTT = _ottFor(_ID);
var SOURCE_ID = _ID;
// Search / detail / episodes path namespace per platform.
var PREFIX = (OTT === 'pv') ? '/mobile/pv' : ((OTT === 'hs' || OTT === 'dp') ? '/mobile/hs' : '/mobile');
var _NAMES = { nf: 'Netflix', pv: 'Prime Video', hs: 'Hotstar', dp: 'Disney+' };

function _poster(id) {
  if (OTT === 'pv') return IMG + '/pv/341/' + id + '.jpg';
  if (OTT === 'hs' || OTT === 'dp') return IMG + '/hs/v/166/' + id + '.jpg';
  return IMG + '/poster/v/' + id + '.jpg';
}
function _posterHeaders() { return { 'Referer': MAIN + '/home', 'User-Agent': UA }; }

// Date.now() may be unavailable in QuickJS; use a monotonic counter for the
// cache-busting `t` query param.
var _tsCounter = 1700000000;
function _ts() { _tsCounter += 1; return _tsCounter; }

// --- Cookie cache (once per runtime session per platform) -------------------
var _cookie = null;
function _getCookie() {
  if (_cookie) return Promise.resolve(_cookie);
  return fetch(MAIN + '/verify.php', {
    method: 'POST',
    followRedirects: false,
    headers: {
      'User-Agent': UA, 'Origin': 'https://net22.cc',
      'Referer': 'https://net22.cc/verify2',
      'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: 'g-recaptcha-response=11111111-2222-3333-4444-555555555555'
  }).then(function (r) {
    var sc = r.headers && r.headers['set-cookie'];
    var th = '';
    if (sc) { var m = String(sc).match(/t_hash_t=([^;]+)/); if (m) th = m[1]; }
    if (!th) throw new Error('NetMirror: could not obtain t_hash_t cookie');
    _cookie = 't_hash_t=' + th + '; ott=' + OTT + '; hd=on';
    return _cookie;
  });
}

function _catFetch(path) {
  return _getCookie().then(function (c) {
    return fetch(MAIN + path, {
      headers: { 'User-Agent': UA, 'Cookie': c, 'Referer': MAIN + '/home' }
    }).then(function (r) { return JSON.parse(r.body || 'null'); });
  });
}

function _mapResults(res) {
  var out = [];
  for (var i = 0; i < res.length; i++) {
    var x = res[i]; if (!x || x.id == null) continue;
    out.push({
      id: String(x.id), title: x.t || '', cover: _poster(x.id),
      coverHeaders: _posterHeaders(), url: String(x.id),
      type: 'movie', sourceId: SOURCE_ID
    });
  }
  return out;
}

// --- Provider API -----------------------------------------------------------
function getInfo() {
  return {
    name: _NAMES[OTT] || 'NetMirror', lang: 'en', baseUrl: MAIN,
    logo: IMG + '/poster/v/placeholder.jpg', type: 'movie', version: '1.1.0'
  };
}

function search(query, page, opts) {
  return _catFetch(PREFIX + '/search.php?s=' + encodeURIComponent(query) + '&t=' + _ts())
    .then(function (j) { return _mapResults((j && j.searchResult) || []); });
}

// Browse: the per-platform home/trending grid is dead, so browse is built from
// search. Netflix has a curated empty-query feed; the other platforms have no
// trending endpoint, so we sample a varied catalog by merging several common
// queries and de-duping. Cached once, then partitioned into the three Home rows.
var _browse = null;
function _searchRaw(q) {
  return _catFetch(PREFIX + '/search.php?s=' + encodeURIComponent(q) + '&t=' + _ts())
    .then(function (j) { return _mapResults((j && j.searchResult) || []); })
    .catch(function () { return []; });
}
function _browseFeed() {
  if (_browse) return Promise.resolve(_browse);
  if (OTT === 'nf') {
    return _searchRaw('').then(function (feed) { _browse = feed; return feed; });
  }
  var qs = ['the', 'a', 'man', 'love', 'star', 'life'];
  return Promise.all(qs.map(_searchRaw)).then(function (lists) {
    var seen = {}, out = [];
    for (var i = 0; i < lists.length; i++) {
      for (var k = 0; k < lists[i].length; k++) {
        var it = lists[i][k];
        if (it && !seen[it.id]) { seen[it.id] = 1; out.push(it); }
      }
    }
    _browse = out;
    return out;
  });
}

function popular(opts) {
  var dr = (opts && opts.dateRange != null) ? opts.dateRange : 1;
  return _browseFeed().then(function (feed) {
    if (!feed.length) return [];
    var third = Math.ceil(feed.length / 3);
    var start = (dr <= 1) ? 0 : (dr <= 30 ? third : third * 2);
    var slice = feed.slice(start, start + third);
    return slice.length ? slice : feed;
  }).catch(function () { return []; });
}

// CloudStream-style home rows. NetMirror has no live category/trending grid,
// so each row is seeded by a different query — giving genuinely distinct rows
// instead of three slices of one feed. Netflix additionally has a curated
// empty-query feed that makes a good "Trending" hero + row. Empty rows are
// dropped app-side.
function getHome(opts) {
  var rows;
  if (OTT === 'nf') {
    rows = [
      { title: 'Trending on Netflix', q: '' },
      { title: 'Action & Adventure',  q: 'man' },
      { title: 'Romance',             q: 'love' },
      { title: 'Sci-Fi & Fantasy',    q: 'star' }
    ];
  } else {
    rows = [
      { title: 'Popular',             q: 'the' },
      { title: 'Action & Adventure',  q: 'man' },
      { title: 'Romance',             q: 'love' },
      { title: 'Sci-Fi & Fantasy',    q: 'star' },
      { title: 'Drama',               q: 'life' }
    ];
  }
  return Promise.all(rows.map(function (r) {
    return _searchRaw(r.q).then(function (items) {
      return { title: r.title, items: items };
    });
  }));
}

function _trim(s) { return String(s).replace(/^\s+|\s+$/g, ''); }

function _seasonEpisodes(seriesId, seasonId, acc, page, resolve) {
  if (page > 10) { resolve(acc); return; }
  _catFetch(PREFIX + '/episodes.php?s=' + seasonId + '&series=' + seriesId + '&t=' + _ts() + '&page=' + page)
    .then(function (data) {
      var eps = (data && data.episodes) || [];
      for (var i = 0; i < eps.length; i++) acc.push(eps[i]);
      if (data && data.nextPageShow) _seasonEpisodes(seriesId, seasonId, acc, page + 1, resolve);
      else resolve(acc);
    })
    .catch(function () { resolve(acc); });
}

function _collectSeasons(seriesId, seasons) {
  var all = [];
  var chain = Promise.resolve();
  seasons.forEach(function (s) {
    chain = chain.then(function () {
      return new Promise(function (resolve) {
        _seasonEpisodes(seriesId, s.id, [], 1, function (eps) {
          for (var i = 0; i < eps.length; i++) all.push(eps[i]);
          resolve();
        });
      });
    });
  });
  return chain.then(function () { return all; });
}

function _mapEpisodes(raw, fallbackId, fallbackTitle) {
  var out = [], n = 0;
  for (var i = 0; i < raw.length; i++) {
    var e = raw[i]; if (!e) continue;
    n += 1;
    var label = (e.s ? e.s : '') + (e.s ? ' ' : '') + (e.ep || 'Episode');
    out.push({
      id: String(e.id != null ? e.id : fallbackId),
      title: _trim(label) || (fallbackTitle || 'Episode'),
      number: n,
      url: String(e.id != null ? e.id : fallbackId)
    });
  }
  return out;
}

function getDetail(url, opts) {
  var id = String(url);
  return _catFetch(PREFIX + '/post.php?id=' + id + '&t=' + _ts()).then(function (p) {
    p = p || {};
    var title = p.title || id;
    var description = htmlText(p.desc || p.m_desc || '');
    var genres = String(p.genre || '').split(',').map(_trim).filter(function (g) { return g.length > 0; });

    // Cast — split the comma-separated `cast` (fall back to `short_cast`)
    // into clean names. Append director / creator when present so the Cast
    // tab carries the people behind the title too. De-duped, blanks dropped.
    var castRaw = String(p.cast || p.short_cast || '');
    var cast = castRaw.split(',').map(_trim).filter(function (c) { return c.length > 0; });
    [p.director, p.creator].forEach(function (extra) {
      String(extra || '').split(',').map(_trim).forEach(function (name) {
        if (name.length > 0 && cast.indexOf(name) < 0) cast.push(name);
      });
    });

    // Release year — surfaced verbatim when present, else null (the UI
    // omits the segment rather than guessing).
    var year = p.year ? String(p.year) : (p.released ? String(p.released) : null);

    function finish(episodes) {
      return {
        id: id, title: title, englishTitle: null, cover: _poster(id),
        coverHeaders: _posterHeaders(), url: id, description: description,
        status: 'unknown', genres: genres, studios: [], type: 'movie',
        sourceId: SOURCE_ID, episodes: episodes, cast: cast, year: year
      };
    }

    var hasSeasons = p.season && p.season.length > 0;
    var rawEps = p.episodes;
    var hasEpisodeObjs = rawEps && rawEps.length > 0 &&
      typeof rawEps[0] === 'object' && rawEps[0] !== null;

    if (hasSeasons) {
      return _collectSeasons(id, p.season).then(function (all) {
        var eps = _mapEpisodes(all, id, title);
        if (eps.length === 0) eps = [{ id: id, title: title || 'Movie', number: 1, url: id }];
        return finish(eps);
      });
    }
    if (hasEpisodeObjs) {
      var eps = _mapEpisodes(rawEps, id, title);
      if (eps.length === 0) eps = [{ id: id, title: title || 'Movie', number: 1, url: id }];
      return finish(eps);
    }
    return finish([{ id: id, title: title || 'Movie', number: 1, url: id }]);
  });
}

function getEpisodes(url, opts) {
  return getDetail(url, opts).then(function (d) { return d.episodes; });
}

// --- Video resolution -------------------------------------------------------
var _apiBase = null;
function _decodeB64(b64) {
  var bytes = base64ToBytes(b64), s = '';
  for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return s;
}
function _resolveApi() {
  if (_apiBase) return Promise.resolve(_apiBase);
  var i = 0;
  function tryNext() {
    if (i >= NEWTV_DOMAINS.length) return Promise.reject(new Error('NetMirror: no NewTV resolver'));
    var domain = NEWTV_DOMAINS[i++];
    return fetch(domain + '/checknewtv.php', {
      headers: { 'User-Agent': UA, 'X-Requested-With': 'NetmirrorNewTV v1.0' }
    }).then(function (r) {
      var j; try { j = JSON.parse(r.body || 'null'); } catch (e) { j = null; }
      if (j && j.token_hash) { _apiBase = _decodeB64(j.token_hash); return _apiBase; }
      return tryNext();
    }).catch(function () { return tryNext(); });
  }
  return tryNext();
}

// The NewTV API returns the SAME master endpoint (/newtv/hls/<ott>/<id>.m3u8)
// for every id, but only *playable* ids (a real episode id, or a movie id)
// yield a complete master with #EXT-X-STREAM-INF video variants. Collection ids
// (a series id, a season id) return a malformed audio-only stub with a broken
// empty-host URL (`https:///files/...`) and NO video — libmpv renders that as a
// black screen. We fetch the master, keep it only if it actually contains video,
// and reject the stub so the player surfaces a clean error / falls through
// instead of silently failing. (Confirmed live, 2026-06: episode ids 80187190…
// play; series id 80187302 / season id 80187189 return the broken stub.)
function _looksPlayable(m3u8) {
  var s = String(m3u8 || '');
  // A complete master has at least one video variant. Reject the known stub:
  // an audio-only playlist whose URI has an empty host (`https:///files/...`).
  if (s.indexOf('#EXT-X-STREAM-INF') >= 0) return true;
  return false;
}

function getVideoSources(episodeUrl) {
  var epId = String(episodeUrl);
  return _resolveApi().then(function (apiBase) {
    return _getCookie().then(function (cookie) {
      return fetch(apiBase + '/newtv/player.php?id=' + epId, {
        headers: {
          'User-Agent': NEWTV_UA, 'X-Requested-With': 'NetmirrorNewTV v1.0',
          'Accept': 'application/json, text/plain, */*',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache', 'Expires': '0',
          'Ott': OTT, 'Usertoken': '', 'Cookie': cookie
        }
      }).then(function (r) {
        var j; try { j = JSON.parse(r.body || 'null'); } catch (e) { j = null; }
        if (!j || j.status !== 'ok' || !j.video_link) throw new Error('NetMirror: no stream');
        var masterUrl = j.video_link;
        var referer = j.referer || MAIN;
        // Playback headers: the master AND its variant playlists/segments are
        // gated on Referer + `hd=on` (variants 404 without them). media_kit
        // applies these to all child HLS requests for the media.
        var playHeaders = { 'Referer': referer, 'Cookie': 'hd=on', 'User-Agent': NEWTV_UA };
        // Validate the master actually carries video before handing it to the
        // player; reject the audio-only stub returned for non-playable ids.
        return fetch(masterUrl, { headers: playHeaders }).then(function (mr) {
          if (!_looksPlayable(mr && mr.body)) {
            throw new Error('NetMirror: stream not available for this title (no video variants)');
          }
          return [{
            url: masterUrl, quality: 'auto', container: 'hls',
            headers: playHeaders, kind: 'raw', audioLang: '', subtitles: []
          }];
        });
      });
    });
  });
}
