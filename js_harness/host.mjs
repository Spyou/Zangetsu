// Pure-Node mirror of kJsBootstrap + wrapProviderSource + wrapExtractorSource.
// Lets provider/extractor contracts be tested without Flutter/QuickJS.
import fs from 'node:fs';
import nodeCrypto from 'node:crypto';

globalThis.__providers = globalThis.__providers || {};
globalThis.__extractors = globalThis.__extractors || {};

globalThis.__fetch = async function (src, u, opts) {
  opts = opts || {};
  const headers = Object.assign(
    { 'User-Agent': 'Mozilla/5.0 Chrome/120.0', Accept: '*/*' },
    opts.headers || {});
  const init = { method: opts.method || 'GET', headers, body: opts.body };
  if (opts.followRedirects === false) init.redirect = 'manual';
  const r = await fetch(u, init);
  const text = await r.text();
  const hdrs = Object.fromEntries(r.headers.entries());
  // undici hides multiple Set-Cookie from entries(); surface them explicitly.
  const sc = typeof r.headers.getSetCookie === 'function'
    ? r.headers.getSetCookie()
    : null;
  if (sc && sc.length) hdrs['set-cookie'] = sc.join(', ');
  else { const one = r.headers.get('set-cookie'); if (one) hdrs['set-cookie'] = one; }
  return {
    ok: r.ok, status: r.status, statusText: r.statusText,
    headers: hdrs, url: r.url, body: text,
    text: async () => text, json: async () => JSON.parse(text),
  };
};

globalThis.__console = function (src, level, args) {
  const parts = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    parts.push(typeof a === 'string' ? a : JSON.stringify(a));
  }
  console.log('[' + src + '/js ' + level + ']', parts.join(' '));
};

globalThis.htmlText = (s) => String(s || '')
  .replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
  .replace(/&#39;/g, "'").trim();

globalThis.absUrl = (h, b) => /^https?:\/\//i.test(h) ? h
  : h.startsWith('//') ? 'https:' + h
  : b ? (h.startsWith('/') ? b.match(/^(https?:\/\/[^/]+)/)[1] + h : b.replace(/\/$/, '') + '/' + h)
  : h;

// Dean-Edwards p,a,c,k,e,d unpacker (base-62), no eval. Returns input unchanged
// if not packed. Mirrors globalThis.unpackJs in js_bootstrap.dart.
globalThis.unpackJs = function (source) {
  const s = String(source);
  if (s.indexOf('}(') === -1 || s.indexOf(".split('|')") === -1) return s;
  let body = s.slice(s.indexOf("}('") + 3, s.indexOf(".split('|'),0,{}))"));
  body = body.replace(/\\'/g, "'");
  const payload = body.slice(0, body.indexOf("',"));
  const dict = body.slice(body.indexOf("'", body.indexOf("',") + 2) + 1, body.lastIndexOf("'")).split('|');
  const r62 = (t) => [...t].reduce((a, c) => a * 62 +
    (c <= '9' ? c.charCodeAt(0) - 48 : c >= 'a' ? c.charCodeAt(0) - 87 : c.charCodeAt(0) - 29), 0);
  return payload.replace(/[0-9A-Za-z]+/g, (k) => {
    const i = r62(k);
    return i < dict.length && dict[i] !== '' ? dict[i] : k;
  });
};

globalThis.sha256Hex = async function (message) {
  return nodeCrypto.createHash('sha256').update(String(message)).digest('hex');
};
globalThis.aesCtrDecrypt = async function (opts) {
  const key = Buffer.from(opts.keyHex, 'hex');
  const ctr = Buffer.from(opts.counterHex, 'hex');
  const data = Buffer.from(opts.dataB64, 'base64');
  const d = nodeCrypto.createDecipheriv('aes-256-ctr', key, ctr);
  return Buffer.concat([d.update(data), d.final()]).toString('utf8');
};
globalThis.base64ToBytes = (b64) => Array.from(Buffer.from(String(b64), 'base64'));
globalThis.bytesToHex = (bytes) => Buffer.from(bytes).toString('hex');
globalThis.bytesToB64 = (bytes) => Buffer.from(bytes).toString('base64');

// Shared extractor dispatcher (mirrors the runtime helper). Parses the host
// from `embedUrl` and routes to the registered extractor.
globalThis.extractVideo = function (embedUrl, opts) {
  const m = String(embedUrl).match(/^https?:\/\/([^/]+)/i);
  const host = m ? m[1].toLowerCase().replace(/^www\./, '') : '';
  const ex = globalThis.__extractors[host];
  if (!ex) return Promise.reject('No extractor for host: ' + host);
  return Promise.resolve(ex.extract(embedUrl, opts || {}));
};

globalThis.__callProvider = function (sourceId, method, argsJson) {
  let args;
  try { args = JSON.parse(argsJson || '[]'); } catch (e) { return Promise.reject('bad args'); }
  const ns = globalThis.__providers[sourceId];
  if (!ns) return Promise.reject('not loaded: ' + sourceId);
  const fn = ns[method];
  if (typeof fn !== 'function') return Promise.reject('missing method: ' + method);
  try { return Promise.resolve(fn.apply(null, args)).then((v) => JSON.stringify(v == null ? null : v)); }
  catch (e) { return Promise.reject(String(e.message || e)); }
};

function wrapProvider(sourceId, src) {
  return `(function(){
    var __SOURCE_ID='${sourceId}';
    var fetch=function(u,o){return globalThis.__fetch(__SOURCE_ID,u,o);};
    var extractVideo=function(u,o){return globalThis.extractVideo(u,o);};
    var console={log:function(){globalThis.__console(__SOURCE_ID,'log',arguments);},
      warn:function(){globalThis.__console(__SOURCE_ID,'warn',arguments);},
      error:function(){globalThis.__console(__SOURCE_ID,'error',arguments);}};
    ${src}
    globalThis.__providers['${sourceId}']={
      getInfo:typeof getInfo==='function'?getInfo:null,
      getHome:typeof getHome==='function'?getHome:null,
      search:typeof search==='function'?search:null,
      popular:typeof popular==='function'?popular:null,
      getDetail:typeof getDetail==='function'?getDetail:null,
      getEpisodes:typeof getEpisodes==='function'?getEpisodes:null,
      getVideoSources:typeof getVideoSources==='function'?getVideoSources:null,
      getSettings:typeof getSettings==='function'?getSettings:null
    };
  })();`;
}

function wrapExtractor(src) {
  return `(function(){
    var fetch=function(u,o){return globalThis.__fetch('extractor',u,o);};
    var console={log:function(){globalThis.__console('extractor','log',arguments);},
      warn:function(){globalThis.__console('extractor','warn',arguments);},
      error:function(){globalThis.__console('extractor','error',arguments);}};
    ${src}
    var __info=getInfo();
    var __hosts=(__info.hosts||[]).slice();
    for (var i=0;i<__hosts.length;i++){
      globalThis.__extractors[String(__hosts[i]).toLowerCase().replace(/^www\\./,'')]=
        { info:__info, extract:extract };
    }
  })();`;
}

export function loadProvider(sourceId, fileUrl) {
  const src = fs.readFileSync(fileUrl, 'utf8');
  (0, eval)(wrapProvider(sourceId, src));
}

export function loadExtractor(fileUrl) {
  const src = fs.readFileSync(fileUrl, 'utf8');
  (0, eval)(wrapExtractor(src));
}

export function callProvider(sourceId, method, args) {
  return globalThis.__callProvider(sourceId, method, JSON.stringify(args));
}
