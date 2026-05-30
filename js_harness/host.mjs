// Pure-Node mirror of kJsBootstrap + wrapProviderSource + wrapExtractorSource.
// Lets provider/extractor contracts be tested without Flutter/QuickJS.
import fs from 'node:fs';

globalThis.__providers = globalThis.__providers || {};
globalThis.__extractors = globalThis.__extractors || {};

globalThis.__fetch = async function (src, u, opts) {
  opts = opts || {};
  const headers = Object.assign(
    { 'User-Agent': 'Mozilla/5.0 Chrome/120.0', Accept: '*/*' },
    opts.headers || {});
  const r = await fetch(u, { method: opts.method || 'GET', headers, body: opts.body });
  const text = await r.text();
  return {
    ok: r.ok, status: r.status, statusText: r.statusText,
    headers: Object.fromEntries(r.headers.entries()), url: r.url, body: text,
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
      search:typeof search==='function'?search:null,
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
