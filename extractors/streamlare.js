// streamlare extractor (API: slwatch.co). No crypto; plain JSON.
function getInfo() {
  return { id: 'streamlare', name: 'Streamlare', version: '1.0.0',
           hosts: ['streamlare.com', 'slwatch.co', 'slmaxed.com', 'sltube.org', 'streamlare.cc'] };
}
function _id(url) { return String(url).split(/[?#]/)[0].replace(/\/$/, '').split('/').pop(); }
globalThis.__streamlareId = _id;

function _parse(jsonText, headers) {
  var data; try { data = JSON.parse(jsonText); } catch (e) { return []; }
  if (!data || data.status === 'error') return [];
  var res = data.result || {};
  var out = [];
  for (var k in res) {
    if (!res.hasOwnProperty(k)) continue;
    var r = res[k];
    var file = String(r.file || '').replace(/\\\//g, '/').replace(/\\/g, '');
    if (!file) continue;
    var isHls = ((r.type || data.type || '') + '').toLowerCase().indexOf('hls') !== -1;
    out.push({ url: file, quality: r.label || k || 'auto', container: isHls ? 'hls' : 'mp4',
               headers: headers || {}, kind: 'sub', audioLang: 'ja', subtitles: [] });
  }
  return out;
}
globalThis.__streamlareParse = _parse;

function extract(url, opts) {
  opts = opts || {}; var _kind = opts.kind || 'sub'; var _lang = opts.audioLang || (_kind === 'dub' ? 'en' : 'ja');
  var headers = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36', 'Referer': 'https://slwatch.co/' };
  var body = JSON.stringify({ id: _id(url) });
  return fetch('https://slwatch.co/api/video/stream/get', {
    method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, headers), body: body
  }).then(function (r) {
    var t = r.body || '';
    if (t.charAt(0) !== '{') throw new Error('streamlare: anti-bot / not JSON');
    return _parse(t, headers);
  }).then(function(arr){ return arr.map(function(s){ s.kind = _kind; s.audioLang = _lang; return s; }); });
}
