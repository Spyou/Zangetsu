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
    var eps = _episodesFromDetail(show);
    for (var k = 0; k < eps.length; k++) {
      eps[k].url = 'allanime://' + showId + '/sub/' + eps[k].number;
    }
    return {
      id: showId, title: show.name || showId, cover: show.thumbnail || null,
      url: showId, description: show.description || '', status: 'unknown',
      genres: [], studios: [], type: 'anime', sourceId: SOURCE_ID, episodes: eps
    };
  });
}

function getEpisodes(url) {
  return getDetail(url).then(function (d) { return d.episodes; });
}

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
  return fetch('https://allanime.day' + path, { headers: { 'Referer': REFERER, 'User-Agent': UA } })
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

function getVideoSources(episodeUrl) {
  var m = String(episodeUrl).replace('allanime://', '').split('/');
  var showId = m[0], mode = (m[1] === 'dub') ? 'dub' : 'sub', epNo = m[2];
  return _fetchSourceUrls(showId, mode, epNo).then(function (sourceUrls) {
    var EMBED = { 'Ok': 1, 'Ss-Hls': 1, 'Mp4': 1, 'Sl-mp4': 1 };
    var jobs = [];
    for (var i = 0; i < sourceUrls.length; i++) {
      var su = sourceUrls[i]; var name = su.sourceName || ''; var raw = String(su.sourceUrl || '');
      if (EMBED[name]) continue;
      if (raw.indexOf('--') === 0) {
        var path = decodeSourceUrl(raw);
        if (path.indexOf('/apivtwo/clock') !== -1) jobs.push(_resolveClock(path, mode));
      } else if (/^https?:\/\//.test(raw)) {
        jobs.push(Promise.resolve([{ url: raw, quality: '', container: /\.m3u8/.test(raw) ? 'hls' : 'mp4',
          headers: { 'Referer': REFERER, 'User-Agent': UA }, kind: mode, audioLang: mode === 'dub' ? 'en' : 'ja', subtitles: [] }]));
      }
    }
    return Promise.all(jobs).then(function (lists) {
      var all = []; for (var k = 0; k < lists.length; k++) all = all.concat(lists[k]);
      if (all.length === 0) throw new Error('AllAnime: no playable sources');
      return all;
    });
  });
}
