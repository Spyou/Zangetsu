// Doodstream-family extractor (domains rotate; match loosely). Token-URL scheme, no crypto.
var ALPHA = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
function getInfo() {
  return { id: 'doodstream', name: 'DoodStream', version: '1.0.0',
           hosts: ['dood.to','dood.so','dood.ws','dood.la','dood.li','dood.cx','dood.sh','dood.wf','dood.yt','dood.pm','dood.re','dood.watch','dood.work','doodstream.com','doods.pro','dsvplay.com','ds2play.com','ds2video.com','d000d.com','d0000d.com','dooood.com','vide0.net'] };
}
function _rand10() { var s=''; for (var i=0;i<10;i++) s += ALPHA.charAt(Math.floor(Math.random()*ALPHA.length)); return s; }
function _base(u) { var m = String(u).match(/^(https?:\/\/[^\/]+)/); return m ? m[1] : u; }

function _build(host, pageHtml, passBody, finalEmbedUrl) {
  if (pageHtml.indexOf('/pass_md5/') === -1) return null;
  var m = pageHtml.match(/\/pass_md5\/[^'"]+/);
  if (!m) return null;
  var token = m[0].slice(m[0].lastIndexOf('/') + 1);
  var base = String(passBody).trim();
  if (!base) return null;
  return {
    url: base + _rand10() + '?token=' + token + '&expiry=' + Date.now(),
    quality: '', container: 'mp4',
    headers: { 'Referer': host + '/', 'User-Agent': 'Mozilla/5.0' },
    kind: 'sub', audioLang: 'ja', subtitles: []
  };
}
globalThis.__doodBuild = _build;

function extract(url, opts) {
  var embed = String(url).replace('/d/', '/e/');
  return fetch(embed, {}).then(function (r) {
    var finalUrl = r.url || embed;
    var host = _base(finalUrl);
    var m = (r.body || '').match(/\/pass_md5\/[^'"]+/);
    if (!m) throw new Error('doodstream: no pass_md5');
    return fetch(host + m[0], { headers: { 'Referer': finalUrl, 'User-Agent': 'Mozilla/5.0' } })
      .then(function (p) {
        var s = _build(host, r.body || '', p.body || '', finalUrl);
        if (!s) throw new Error('doodstream: build failed');
        return [s];
      });
  });
}
