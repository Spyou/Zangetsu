/// Shared JS bootstrap loaded once into a single QuickJS runtime that hosts
/// every provider as `__providers[sourceId]` and every extractor as
/// `__extractors[host]`. flutter_js binds each message channel to one
/// runtime (last writer wins), so this design uses ONE runtime and routes
/// by sourceId / host inside the payload.
const String kJsBootstrap = r'''
var __pendingFetches = {};
var __fetchSeq = 0;
globalThis.__providers = globalThis.__providers || {};
globalThis.__extractors = globalThis.__extractors || {};
globalThis.__settings = globalThis.__settings || {};

function __nextFetchId() { __fetchSeq += 1; return 'f' + __fetchSeq; }

globalThis.__resolveFetch = function(id, responseJson) {
  var p = __pendingFetches[id]; if (!p) return;
  delete __pendingFetches[id];
  try { p.resolve(JSON.parse(responseJson)); }
  catch (e) { p.reject('Invalid fetch response JSON: ' + e); }
};

globalThis.__rejectFetch = function(id, reason) {
  var p = __pendingFetches[id]; if (!p) return;
  delete __pendingFetches[id]; p.reject(reason);
};

globalThis.__fetch = function(src, url, opts) {
  opts = opts || {};
  var id = __nextFetchId();
  var payload = {
    __src: src, id: id, url: url,
    method: (opts.method || 'GET').toUpperCase(),
    headers: opts.headers || {},
    body: opts.body == null ? null : (typeof opts.body === 'string' ? opts.body : JSON.stringify(opts.body)),
    responseType: opts.responseType || 'text'
  };
  var promise = new Promise(function(resolve, reject) {
    __pendingFetches[id] = { resolve: resolve, reject: reject };
  });
  sendMessage('fetch', JSON.stringify(payload));
  return promise.then(function(res) {
    return {
      ok: res.status >= 200 && res.status < 300,
      status: res.status, statusText: res.statusText || '',
      headers: res.headers || {}, url: res.url || url,
      text: function() { return Promise.resolve(res.body || ''); },
      json: function() {
        try { return Promise.resolve(JSON.parse(res.body || 'null')); }
        catch (e) { return Promise.reject('Invalid JSON: ' + e); }
      },
      body: res.body || ''
    };
  });
};

globalThis.__console = function(src, level, args) {
  try {
    var parts = [];
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      parts.push(typeof a === 'string' ? a : JSON.stringify(a));
    }
    sendMessage('console', JSON.stringify({ __src: src, level: level, message: parts.join(' ') }));
  } catch (e) {}
};

// Shared extractor dispatcher. Parses the host from `embedUrl` and routes
// to the registered extractor's extract(url, opts).
globalThis.extractVideo = function(embedUrl, opts) {
  var m = String(embedUrl).match(/^https?:\/\/([^\/]+)/i);
  var host = m ? m[1].toLowerCase().replace(/^www\./, '') : '';
  var ex = globalThis.__extractors[host];
  if (!ex) return Promise.reject('No extractor for host: ' + host);
  try { return Promise.resolve(ex.extract(embedUrl, opts || {})); }
  catch (e) { return Promise.reject(String((e && e.message) || e)); }
};

globalThis.__callProvider = function(sourceId, method, argsJson) {
  var args;
  try { args = JSON.parse(argsJson || '[]'); }
  catch (e) { return Promise.reject('Bad argsJson: ' + e); }
  var ns = globalThis.__providers[sourceId];
  if (!ns) return Promise.reject('Provider not loaded: ' + sourceId);
  var fn = ns[method];
  if (typeof fn !== 'function') return Promise.reject('Provider ' + sourceId + ' missing method: ' + method);
  function stringifyErr(e) {
    if (!e) return 'unknown error';
    if (typeof e === 'string') return e;
    if (e instanceof Error) return e.message || String(e);
    if (typeof e === 'object' && e.message) return String(e.message);
    try { return JSON.stringify(e); } catch (_) { return String(e); }
  }
  try {
    var r = fn.apply(null, args);
    return Promise.resolve(r)
      .then(function(v) { return JSON.stringify(v == null ? null : v); })
      .catch(function(e) { return Promise.reject(stringifyErr(e)); });
  } catch (e) { return Promise.reject(stringifyErr(e)); }
};

globalThis.htmlText = function(html) {
  if (!html) return '';
  return String(html).replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").trim();
};

globalThis.absUrl = function(href, base) {
  if (!href) return '';
  if (/^https?:\/\//i.test(href)) return href;
  if (href.startsWith('//')) return 'https:' + href;
  if (!base) return href;
  if (href.startsWith('/')) {
    var m = base.match(/^(https?:\/\/[^\/]+)/i);
    return m ? m[1] + href : href;
  }
  return base.replace(/\/$/, '') + '/' + href;
};
''';

/// Wraps a provider's JS so it lives in its own namespace with a local
/// `fetch`/`console`/`extractVideo` carrying its sourceId.
String wrapProviderSource(String sourceId, String providerJs) {
  final src = sourceId.replaceAll("'", r"\'");
  return '''
(function(){
  var __SOURCE_ID = '$src';
  var fetch = function(url, opts) { return globalThis.__fetch(__SOURCE_ID, url, opts); };
  var extractVideo = function(url, opts) { return globalThis.extractVideo(url, opts); };
  var console = {
    log:   function() { globalThis.__console(__SOURCE_ID, 'log', arguments); },
    warn:  function() { globalThis.__console(__SOURCE_ID, 'warn', arguments); },
    error: function() { globalThis.__console(__SOURCE_ID, 'error', arguments); },
    info:  function() { globalThis.__console(__SOURCE_ID, 'info', arguments); },
    debug: function() { globalThis.__console(__SOURCE_ID, 'debug', arguments); }
  };
  $providerJs
  globalThis.__providers['$src'] = {
    getInfo:         typeof getInfo === 'function' ? getInfo : null,
    search:          typeof search === 'function' ? search : null,
    getDetail:       typeof getDetail === 'function' ? getDetail : null,
    getEpisodes:     typeof getEpisodes === 'function' ? getEpisodes : null,
    getVideoSources: typeof getVideoSources === 'function' ? getVideoSources : null,
    getSettings:     typeof getSettings === 'function' ? getSettings : null
  };
})();
''';
}

/// Wraps an extractor's JS and registers it under every host in its
/// getInfo().hosts list as `__extractors[host]`.
String wrapExtractorSource(String extractorId, String extractorJs) {
  final src = extractorId.replaceAll("'", r"\'");
  return '''
(function(){
  var __EX_ID = '$src';
  var fetch = function(url, opts) { return globalThis.__fetch('ex:' + __EX_ID, url, opts); };
  var extractVideo = function(url, opts) { return globalThis.extractVideo(url, opts); };
  var console = {
    log:   function() { globalThis.__console('ex:' + __EX_ID, 'log', arguments); },
    warn:  function() { globalThis.__console('ex:' + __EX_ID, 'warn', arguments); },
    error: function() { globalThis.__console('ex:' + __EX_ID, 'error', arguments); }
  };
  $extractorJs
  var __info = (typeof getInfo === 'function') ? getInfo() : { hosts: [] };
  var __hosts = (__info && __info.hosts) ? __info.hosts : [];
  for (var i = 0; i < __hosts.length; i++) {
    var __h = String(__hosts[i]).toLowerCase().replace(/^www\\./, '');
    globalThis.__extractors[__h] = { info: __info, extract: (typeof extract === 'function' ? extract : null) };
  }
})();
''';
}
