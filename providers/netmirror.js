// NetMirror provider — Netflix/Prime mirror (HLS). https://net52.cc

var MAIN = 'https://net52.cc';
var IMG = 'https://imgcdn.kim';
var SOURCE_ID = 'netmirror';
var OTT = 'nf';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

// NewTV resolver domains — tried in order; first that returns a token_hash wins.
var NEWTV_DOMAINS = ['https://mobiledetects.com', 'https://mobidetect.art', 'https://mobidetect.cc'];

// Date.now() may be unavailable in QuickJS; use a monotonic counter for the
// cache-busting `t` query param instead.
var _tsCounter = 1700000000;
function _ts() { _tsCounter += 1; return _tsCounter; }

// --- Cookie cache (once per runtime session; no time-based expiry) ----------
var _cookie = { v: null, at: 0 };

function _getCookie() {
  if (_cookie.v) return Promise.resolve(_cookie.v);
  return fetch(MAIN + '/verify.php', {
    method: 'POST',
    followRedirects: false,
    headers: {
      'User-Agent': UA,
      'Origin': 'https://net22.cc',
      'Referer': 'https://net22.cc/verify2',
      'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: 'g-recaptcha-response=11111111-2222-3333-4444-555555555555'
  }).then(function (r) {
    var sc = r.headers && r.headers['set-cookie'];
    var th = '';
    if (sc) {
      var m = String(sc).match(/t_hash_t=([^;]+)/);
      if (m) th = m[1];
    }
    if (!th) throw new Error('NetMirror: could not obtain t_hash_t cookie');
    _cookie.v = 't_hash_t=' + th + '; ott=nf; hd=on';
    _cookie.at = _ts();
    return _cookie.v;
  });
}

// --- Helpers -----------------------------------------------------------------
function _posterHeaders() { return { 'Referer': MAIN + '/home', 'User-Agent': UA }; }
function _poster(id) { return IMG + '/poster/v/' + id + '.jpg'; }

function _catFetch(path) {
  return _getCookie().then(function (c) {
    return fetch(MAIN + path, {
      headers: { 'User-Agent': UA, 'Cookie': c, 'Referer': MAIN + '/home' }
    }).then(function (r) { return JSON.parse(r.body || 'null'); });
  });
}

// --- Provider API ------------------------------------------------------------
function getInfo() {
  return {
    name: 'NetMirror', lang: 'en', baseUrl: MAIN,
    logo: IMG + '/poster/v/placeholder.jpg', type: 'movie', version: '1.0.0'
  };
}

function search(query, page, opts) {
  return _catFetch('/mobile/search.php?s=' + encodeURIComponent(query) + '&t=' + _ts())
    .then(function (j) {
      var res = (j && j.searchResult) || [];
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
    });
}

// Browse/trending feed = the empty-query search (the old /mobile/home grid is
// dead). It's one UNIFIED list across all OTTs (Netflix/Prime/Hotstar titles
// together), with real titles. Cached once per session.
var _browse = null;
function _browseFeed() {
  if (_browse) return Promise.resolve(_browse);
  return _catFetch('/mobile/search.php?s=&t=' + _ts()).then(function (j) {
    var res = (j && j.searchResult) || [];
    var out = [];
    for (var i = 0; i < res.length; i++) {
      var x = res[i]; if (!x || x.id == null) continue;
      out.push({
        id: String(x.id), title: x.t || '', cover: _poster(x.id),
        coverHeaders: _posterHeaders(), url: String(x.id),
        type: 'movie', sourceId: SOURCE_ID
      });
    }
    _browse = out;
    return out;
  });
}

function popular(opts) {
  var dr = (opts && opts.dateRange != null) ? opts.dateRange : 1;
  return _browseFeed().then(function (feed) {
    if (!feed.length) return search('a', 1, opts);
    // One unified trending list; partition it so the three Home rows each show
    // distinct real titles (dateRange is AllAnime's notion — here it just picks
    // which third of the feed to show).
    var third = Math.ceil(feed.length / 3);
    var start = (dr <= 1) ? 0 : (dr <= 30 ? third : third * 2);
    var slice = feed.slice(start, start + third);
    return slice.length ? slice : feed;
  }).catch(function () { return search('a', 1, opts); });
}

function _trim(s) { return String(s).replace(/^\s+|\s+$/g, ''); }

// Pages through one season's episodes. Returns array of raw episode objects.
function _seasonEpisodes(seriesId, seasonId, acc, page, resolve) {
  if (page > 10) { resolve(acc); return; }
  _catFetch('/mobile/episodes.php?s=' + seasonId + '&series=' + seriesId + '&t=' + _ts() + '&page=' + page)
    .then(function (data) {
      var eps = (data && data.episodes) || [];
      for (var i = 0; i < eps.length; i++) acc.push(eps[i]);
      if (data && data.nextPageShow) _seasonEpisodes(seriesId, seasonId, acc, page + 1, resolve);
      else resolve(acc);
    })
    .catch(function () { resolve(acc); });
}

function _collectSeasons(seriesId, seasons) {
  // Sequentially collect each season's episodes (preserve season order).
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
  var out = [];
  var n = 0;
  for (var i = 0; i < raw.length; i++) {
    var e = raw[i];
    if (!e) continue;
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
  return _catFetch('/mobile/post.php?id=' + id + '&t=' + _ts()).then(function (p) {
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
    // Movie: single episode pointing at the title id.
    return finish([{ id: id, title: title || 'Movie', number: 1, url: id }]);
  });
}

function getEpisodes(url, opts) {
  return getDetail(url, opts).then(function (d) { return d.episodes; });
}

// --- Video resolution --------------------------------------------------------
var _apiBase = null;

function _decodeB64(b64) {
  var bytes = base64ToBytes(b64);
  var s = '';
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
      if (j && j.token_hash) {
        _apiBase = _decodeB64(j.token_hash);
        return _apiBase;
      }
      return tryNext();
    }).catch(function () { return tryNext(); });
  }
  return tryNext();
}

// A title can live on any of the mirrored OTTs; the unified catalog doesn't
// tell us which, so try each backend until one yields a stream.
var OTTS = ['nf', 'pv', 'hs'];

function getVideoSources(episodeUrl) {
  var epId = String(episodeUrl);
  return _resolveApi().then(function (apiBase) {
    return _getCookie().then(function (baseCookie) {
      var i = 0;
      function tryOtt() {
        if (i >= OTTS.length) throw new Error('NetMirror: no stream');
        var ott = OTTS[i++];
        var cookie = baseCookie.replace(/ott=[^;]*/, 'ott=' + ott);
        return fetch(apiBase + '/newtv/player.php?id=' + epId, {
          headers: {
            'User-Agent': UA, 'X-Requested-With': 'NetmirrorNewTV v1.0',
            'Ott': ott, 'Usertoken': '', 'Cookie': cookie
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
          return tryOtt();
        }).catch(function () { return tryOtt(); });
      }
      return tryOtt();
    });
  });
}
