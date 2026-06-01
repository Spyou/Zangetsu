// NetMirror provider — Netflix / Prime / Hotstar / Disney+ mirror (HLS).
// Host: https://net52.cc. ONE file, loaded once per platform under a distinct
// sourceId (netmirror_nf / _pv / _hs / _dp). The platform is derived from the
// runtime-provided __SOURCE_ID, which selects the ott cookie, the path prefix
// (/mobile, /mobile/pv, /mobile/hs) and the poster CDN path. Verified live.

var MAIN = 'https://net52.cc';
var IMG = 'https://imgcdn.kim';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
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

// Browse: the per-platform home grid is dead, so browse from search. Netflix
// has a curated empty-query feed; the other platforms need a query, so we use a
// broad common term. Cached once, then partitioned into the three Home rows.
var _browse = null;
function _browseFeed() {
  if (_browse) return Promise.resolve(_browse);
  var q = (OTT === 'nf') ? '' : 'the';
  return _catFetch(PREFIX + '/search.php?s=' + encodeURIComponent(q) + '&t=' + _ts())
    .then(function (j) { _browse = _mapResults((j && j.searchResult) || []); return _browse; });
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

    function finish(episodes) {
      return {
        id: id, title: title, englishTitle: null, cover: _poster(id),
        coverHeaders: _posterHeaders(), url: id, description: description,
        status: 'unknown', genres: genres, studios: [], type: 'movie',
        sourceId: SOURCE_ID, episodes: episodes
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

function getVideoSources(episodeUrl) {
  var epId = String(episodeUrl);
  return _resolveApi().then(function (apiBase) {
    return _getCookie().then(function (cookie) {
      return fetch(apiBase + '/newtv/player.php?id=' + epId, {
        headers: {
          'User-Agent': UA, 'X-Requested-With': 'NetmirrorNewTV v1.0',
          'Ott': OTT, 'Usertoken': '', 'Cookie': cookie
        }
      }).then(function (r) {
        var j; try { j = JSON.parse(r.body || 'null'); } catch (e) { j = null; }
        if (j && j.status === 'ok' && j.video_link) {
          return [{
            url: j.video_link, quality: 'auto', container: 'hls',
            headers: { 'Referer': j.referer || MAIN, 'Cookie': 'hd=on', 'User-Agent': UA },
            kind: 'raw', audioLang: '', subtitles: []
          }];
        }
        throw new Error('NetMirror: no stream');
      });
    });
  });
}
