// AllAnime provider — https://allanime.to (API: https://api.allanime.day/api)

var API = 'https://api.allanime.day/api';
var REFERER = 'https://youtu-chan.com';
var ORIGIN = 'https://youtu-chan.com';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:150.0) Gecko/20100101 Firefox/150.0';
var SOURCE_ID = 'allanime';
var SOURCES_HASH = 'd405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec';
var ALLANIME_KEY_SEED = 'Xot36i3lK3:v1';

var _HEXMAP = {"79":"A","7a":"B","7b":"C","7c":"D","7d":"E","7e":"F","7f":"G","70":"H","71":"I","72":"J","73":"K","74":"L","75":"M","76":"N","77":"O","68":"P","69":"Q","6a":"R","6b":"S","6c":"T","6d":"U","6e":"V","6f":"W","60":"X","61":"Y","62":"Z","59":"a","5a":"b","5b":"c","5c":"d","5d":"e","5e":"f","5f":"g","50":"h","51":"i","52":"j","53":"k","54":"l","55":"m","56":"n","57":"o","48":"p","49":"q","4a":"r","4b":"s","4c":"t","4d":"u","4e":"v","4f":"w","40":"x","41":"y","42":"z","08":"0","09":"1","0a":"2","0b":"3","0c":"4","0d":"5","0e":"6","0f":"7","00":"8","01":"9","15":"-","16":".","67":"_","46":"~","02":":","17":"/","07":"?","1b":"#","63":"[","65":"]","78":"@","19":"!","1c":"$","1e":"&","10":"(","11":")","12":"*","13":"+","14":",","03":";","05":"=","1d":"%"};

function decodeSourceUrl(s) {
  s = String(s);
  if (s.indexOf('--') !== 0) return s;
  var body = s.slice(2), out = '';
  for (var i = 0; i + 1 < body.length; i += 2) { var ch = _HEXMAP[body.substr(i, 2)]; out += (ch == null ? '' : ch); }
  return out.replace('/clock', '/clock.json');
}
globalThis.__allanimeDecodeSourceUrl = decodeSourceUrl; // test hook

var SEARCH_GQL = 'query( $search: SearchInput $limit: Int $page: Int $translationType: VaildTranslationTypeEnumType $countryOrigin: VaildCountryOriginEnumType ) { shows( search: $search limit: $limit page: $page translationType: $translationType countryOrigin: $countryOrigin ) { edges { _id name thumbnail availableEpisodes __typename } }}';
var SHOW_GQL = 'query ($showId: String!) { show( _id: $showId ) { _id name englishName thumbnail description availableEpisodes availableEpisodesDetail }}';

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

var POPULAR_GQL = 'query($type:VaildPopularTypeEnumType!,$size:Int!,$dateRange:Int,$page:Int,$allowAdult:Boolean,$allowUnknown:Boolean){queryPopular(type:$type,size:$size,dateRange:$dateRange,page:$page,allowAdult:$allowAdult,allowUnknown:$allowUnknown){recommendations{anyCard{_id name englishName thumbnail availableEpisodes __typename}}}}';

function popular(opts) {
  opts = opts || {};
  var vars = { type: 'anime', size: opts.size || 26,
    dateRange: (opts.dateRange == null ? 7 : opts.dateRange),
    page: opts.page || 1, allowAdult: false, allowUnknown: false };
  return _post(POPULAR_GQL, vars).then(function (j) {
    var recs = (j && j.data && j.data.queryPopular && j.data.queryPopular.recommendations) || [];
    var out = [];
    for (var i = 0; i < recs.length; i++) {
      var c = recs[i] && recs[i].anyCard; if (!c || !c._id) continue;
      var ae = c.availableEpisodes || {};
      out.push({ id: c._id, title: c.name, englishTitle: c.englishName || null,
        cover: c.thumbnail || null, url: c._id, type: 'anime', sourceId: SOURCE_ID,
        subCount: ae.sub || 0, dubCount: ae.dub || 0 });
    }
    return out;
  });
}

function getDetail(url, opts) {
  var showId = String(url);
  var cat = (opts && opts.category === 'dub') ? 'dub' : 'sub';
  return _post(SHOW_GQL, { showId: showId }).then(function (j) {
    var show = (j && j.data && j.data.show) || {};
    var aed = show.availableEpisodesDetail || {};
    var ae = show.availableEpisodes || {};
    var keys = (aed[cat] || []).slice().sort(function (a, b) { return parseFloat(a) - parseFloat(b); });
    var eps = [];
    for (var i = 0; i < keys.length; i++) {
      var n = keys[i];
      eps.push({ id: cat + ':' + n, title: 'Episode ' + n, number: parseFloat(n),
        url: 'allanime://' + showId + '/' + cat + '/' + n });
    }
    return { id: showId, title: show.name || showId, englishTitle: show.englishName || null,
      cover: show.thumbnail || null, url: showId, description: show.description || '',
      status: 'unknown', genres: [], studios: [], type: 'anime', sourceId: SOURCE_ID,
      episodes: eps, subCount: (ae.sub != null ? ae.sub : (aed.sub || []).length),
      dubCount: (ae.dub != null ? ae.dub : (aed.dub || []).length) };
  });
}

function getEpisodes(url, opts) { return getDetail(url, opts).then(function (d) { return d.episodes; }); }

var SOURCES_GQL = 'query ($showId: String!, $translationType: VaildTranslationTypeEnumType!, $episodeString: String!) { episode( showId: $showId translationType: $translationType episodeString: $episodeString ) { episodeString sourceUrls }}';

function _fetchSourceUrls(showId, mode, epNo) {
  var variables = encodeURIComponent(JSON.stringify({ showId: showId, translationType: mode, episodeString: String(epNo) }));
  var extensions = encodeURIComponent(JSON.stringify({ persistedQuery: { version: 1, sha256Hash: SOURCES_HASH } }));
  var url = API + '?variables=' + variables + '&extensions=' + extensions;
  return fetch(url, { headers: { 'Referer': REFERER, 'Origin': ORIGIN, 'User-Agent': UA } })
    .then(function (r) {
      var j; try { j = JSON.parse(r.body || 'null'); } catch (e) { throw new Error('AllAnime sources: bad JSON'); }
      var data = j && j.data;
      if (data && data.tobeparsed) return _decryptTobeparsed(data.tobeparsed);
      if (data && data.episode && data.episode.sourceUrls) return data.episode.sourceUrls;
      throw new Error('AllAnime: no sources in response');
    });
}

function _decryptTobeparsed(b64) {
  return sha256Hex(ALLANIME_KEY_SEED).then(function (keyHex) {
    var bytes = base64ToBytes(b64);
    var iv = bytes.slice(1, 13);
    var counterHex = bytesToHex(iv) + '00000002';
    var ct = bytes.slice(13, bytes.length - 16);
    return aesCtrDecrypt({ keyHex: keyHex, counterHex: counterHex, dataB64: bytesToB64(ct) })
      .then(function (plain) {
        var obj; try { obj = JSON.parse(plain); } catch (e) { throw new Error('AllAnime: decrypt parse failed'); }
        return (obj.episode && obj.episode.sourceUrls) || obj.sourceUrls || [];
      });
  });
}

function _resolveClock(path, mode) {
  return fetch('https://allanime.day' + path, { headers: { 'Referer': REFERER, 'User-Agent': UA }, timeoutMs: 8000 })
    .then(function (r) {
      var j; try { j = JSON.parse(r.body || 'null'); } catch (e) { return []; }
      var links = (j && j.links) || [];
      var out = [];
      for (var i = 0; i < links.length; i++) {
        var lk = links[i]; var u = lk.link || lk.url; if (!u) continue;
        var isHls = lk.hls === true || /\.m3u8/.test(u) || /repackager\.wixmp/.test(u);
        out.push({ url: u, quality: lk.resolutionStr || '', container: isHls ? 'hls' : 'mp4',
          headers: { 'Referer': REFERER, 'User-Agent': UA }, kind: mode, audioLang: mode === 'dub' ? 'en' : 'ja', subtitles: [] });
      }
      return out;
    });
}

function _settleWithDeadline(jobs, deadlineMs) {
  return new Promise(function (resolve) {
    var results = [];
    var pending = jobs.length;
    var done = false;
    function finish() { if (!done) { done = true; resolve(results); } }
    if (pending === 0) { resolve(results); return; }
    for (var i = 0; i < jobs.length; i++) {
      Promise.resolve(jobs[i])
        .then(function (arr) { if (arr && arr.length) results = results.concat(arr); })
        .catch(function () {})
        .then(function () { pending -= 1; if (pending === 0) finish(); });
    }
    setTimeout(finish, deadlineMs);
  });
}
globalThis.__allanimeSettleWithDeadline = _settleWithDeadline; // test hook

function getVideoSources(episodeUrl) {
  var m = String(episodeUrl).replace('allanime://', '').split('/');
  var showId = m[0], mode = (m[1] === 'dub') ? 'dub' : 'sub', epNo = m[2];
  return _fetchSourceUrls(showId, mode, epNo).then(function (sourceUrls) {
    var SKIP = { 'Ss-Hls': 1 };                       // dead host
    var EMBED = { 'Ok': 1, 'Mp4': 1, 'Sl-mp4': 1 };   // resolve via extractVideo
    var jobs = [];
    for (var i = 0; i < sourceUrls.length; i++) {
      var su = sourceUrls[i]; var name = su.sourceName || ''; var raw = String(su.sourceUrl || '');
      if (SKIP[name]) continue;
      if (EMBED[name] && /^https?:\/\//.test(raw)) {
        jobs.push(extractVideo(raw, { headers: { 'Referer': REFERER, 'User-Agent': UA }, kind: mode, audioLang: mode === 'dub' ? 'en' : 'ja' }).catch(function () { return []; }));
        continue;
      }
      if (raw.indexOf('--') === 0) {
        var path = decodeSourceUrl(raw);
        if (path.indexOf('/apivtwo/clock') !== -1) jobs.push(_resolveClock(path, mode).catch(function () { return []; }));
      } else if (/^https?:\/\//.test(raw)) {
        jobs.push(Promise.resolve([{ url: raw, quality: '', container: /\.m3u8/.test(raw) ? 'hls' : 'mp4',
          headers: { 'Referer': REFERER, 'User-Agent': UA }, kind: mode, audioLang: mode === 'dub' ? 'en' : 'ja', subtitles: [] }]));
      }
    }
    var deadline = (typeof globalThis.__allanimeDeadlineMs === 'number') ? globalThis.__allanimeDeadlineMs : 5000;
    return _settleWithDeadline(jobs, deadline).then(function (all) {
      if (all.length === 0) throw new Error('AllAnime: no playable sources');
      return all;
    });
  });
}
