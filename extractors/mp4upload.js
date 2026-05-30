// mp4upload.com embed extractor. Uses shared globalThis.unpackJs for packed pages.
function getInfo() {
  return { id: 'mp4upload', name: 'Mp4upload', version: '1.0.0',
           hosts: ['mp4upload.com', 'www.mp4upload.com'] };
}

function _parse(html) {
  var js = html;
  var pk = html.match(/(eval\(function\(p,a,c,k,e,d\)[\s\S]*?\.split\('\|'\),0,\{\}\)\))/);
  if (pk && typeof unpackJs === 'function') js = unpackJs(pk[1]);
  var u = js.match(/player\.src\("([^"]+)"/) || js.match(/src:\s*"([^"]+)"/);
  if (!u) return null;
  var h = js.match(/[^A-Za-z0-9]HEIGHT=(\d+)/);
  return {
    url: u[1], quality: h ? h[1] + 'p' : 'auto', container: 'mp4',
    headers: { 'Referer': 'https://www.mp4upload.com/', 'User-Agent': 'Mozilla/5.0' },
    kind: 'sub', audioLang: 'ja', subtitles: []
  };
}
globalThis.__mp4uploadParse = _parse;

function extract(url, opts) {
  var headers = { 'Referer': 'https://mp4upload.com/', 'User-Agent': 'Mozilla/5.0' };
  return fetch(url, { headers: headers }).then(function (r) {
    var s = _parse(r.body || '');
    if (!s) throw new Error('mp4upload: no source');
    return [s];
  });
}
