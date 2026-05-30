// ok.ru / Odnoklassniki video embed extractor.
var Q = { mobile: '144p', lowest: '240p', low: '360p', sd: '480p',
          hd: '720p', full: '1080p', quad: '1440p', ultra: '2160p' };

function getInfo() {
  return { id: 'okru', name: 'OK.ru', version: '1.0.0',
           hosts: ['ok.ru', 'www.ok.ru', 'm.ok.ru', 'mobile.ok.ru',
                   'odnoklassniki.ru', 'www.odnoklassniki.ru'] };
}

function _parse(html, headers) {
  var m = html.match(/data-options="([^"]*)"/);
  if (!m) return [];
  var opt;
  try { opt = JSON.parse(m[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&')); }
  catch (e) { return []; }
  var meta;
  try { meta = JSON.parse(opt.flashvars.metadata); } catch (e) { return []; }
  var h = headers || {};
  var out = [];
  var hls = meta.hlsMasterPlaylistUrl || meta.hlsManifestUrl || meta.ondemandHls;
  if (hls) out.push({ url: hls, quality: 'auto', container: 'hls', headers: h, kind: 'sub', audioLang: 'ja', subtitles: [] });
  var vids = meta.videos || [];
  for (var i = 0; i < vids.length; i++) {
    var v = vids[i];
    if (v && typeof v.url === 'string' && /^https?:\/\//.test(v.url)) {
      out.push({ url: v.url, quality: Q[v.name] || v.name || '', container: 'mp4', headers: h, kind: 'sub', audioLang: 'ja', subtitles: [] });
    }
  }
  return out;
}
globalThis.__okruParse = _parse;

function extract(url, opts) {
  opts = opts || {};
  var headers = opts.headers || { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36' };
  return fetch(url, { headers: headers }).then(function (r) { return _parse(r.body || '', headers); });
}
