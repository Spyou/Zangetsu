// LNReader harness: an async fetch bridge + a require() shim so a real
// LNReader plugin (CommonJS) runs unmodified in QuickJS. Loaded AFTER the
// cheerio bundle (which sets globalThis.__cheerio / __htmlparser2).
//
// The JS<->Dart message channel (sendMessage/onMessage) only works on a real
// device, not on the host QuickJS FFI runtime — so fetch goes through an
// outbox the Dart driver polls with __drainOutbox() and answers with
// __resolveFetch(id, json). See LnReaderRuntime.call() for the driver loop.

globalThis.__pendingFetch = {};
globalThis.__fetchSeq = 0;
globalThis.__outbox = [];
globalThis.__drainOutbox = function () {
  var o = globalThis.__outbox;
  globalThis.__outbox = [];
  return JSON.stringify(o);
};
globalThis.__resolveFetch = function (id, json) {
  var p = globalThis.__pendingFetch[id];
  if (!p) return;
  delete globalThis.__pendingFetch[id];
  try { p.resolve(JSON.parse(json)); } catch (e) { p.reject(e); }
};
globalThis.__rejectFetch = function (id, msg) {
  var p = globalThis.__pendingFetch[id];
  if (!p) return;
  delete globalThis.__pendingFetch[id];
  p.reject(new Error(msg));
};
// Minimal FormData — QuickJS ships none. Madara-template novel plugins (WBNovel
// & co.) do `new FormData()` in parseNovel to POST the chapter list to
// wp-admin/admin-ajax.php; without it they throw "'FormData' is not defined"
// the moment you OPEN a novel (the list browses fine, the novel won't read).
// We just hold the appended fields; __rawFetch serialises them below.
function __FormData() { this.__fd = []; }
__FormData.prototype.append = function (k, v) { this.__fd.push([String(k), String(v)]); };
__FormData.prototype.set = function (k, v) {
  for (var i = 0; i < this.__fd.length; i++) {
    if (this.__fd[i][0] === String(k)) { this.__fd[i][1] = String(v); return; }
  }
  this.append(k, v);
};
__FormData.prototype.get = function (k) {
  for (var i = 0; i < this.__fd.length; i++) if (this.__fd[i][0] === String(k)) return this.__fd[i][1];
  return null;
};
__FormData.prototype.has = function (k) { return this.get(k) !== null; };
__FormData.prototype.delete = function (k) {
  this.__fd = this.__fd.filter(function (e) { return e[0] !== String(k); });
};
globalThis.FormData = __FormData;

function __rawFetch(url, init) {
  init = init || {};
  // A FormData body can't cross the JSON outbox — serialise it to
  // x-www-form-urlencoded (WordPress admin-ajax reads $_POST identically to a
  // multipart post for these plain string fields).
  if (init.body instanceof __FormData) {
    var parts = [];
    var fd = init.body.__fd;
    for (var i = 0; i < fd.length; i++) {
      parts.push(encodeURIComponent(fd[i][0]) + '=' + encodeURIComponent(fd[i][1]));
    }
    var headers = {};
    var src = init.headers || {};
    for (var h in src) headers[h] = src[h];
    if (!headers['Content-Type'] && !headers['content-type']) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    init = { method: init.method || 'POST', headers: headers, body: parts.join('&') };
  }
  return new Promise(function (resolve, reject) {
    var id = ++globalThis.__fetchSeq;
    globalThis.__pendingFetch[id] = { resolve: resolve, reject: reject };
    globalThis.__outbox.push({ id: id, url: String(url), init: init });
  });
}
function fetchApi(url, init) {
  return __rawFetch(url, init).then(function (r) {
    return {
      ok: r.status >= 200 && r.status < 300,
      status: r.status,
      url: r.url || String(url),
      headers: { get: function () { return null; } },
      text: function () { return Promise.resolve(r.body); },
      json: function () { return Promise.resolve(JSON.parse(r.body)); },
    };
  });
}

// ── @libs + node-module shims LNReader plugins require() ─────────────────────
function __require(name) {
  switch (name) {
    case 'cheerio': return globalThis.__cheerio;
    case 'htmlparser2': return globalThis.__htmlparser2;
    // dayjs (pre-extended with customParseFormat/relativeTime/utc in the bundle).
    // Madara-template plugins (e.g. WBNovel) require('dayjs') at load time; without
    // it they throw 'unknown module: dayjs' before any fetch → "isn't responding".
    case 'dayjs': return globalThis.__dayjs;
    case '@libs/fetch': return { fetchApi: fetchApi, fetchFile: fetchApi };
    case '@libs/novelStatus': return { NovelStatus: {
      Unknown: 'Unknown', Ongoing: 'Ongoing', Completed: 'Completed',
      Licensed: 'Licensed', PublishingFinished: 'Publishing Finished',
      Cancelled: 'Cancelled', OnHiatus: 'On Hiatus' } };
    case '@libs/isAbsoluteUrl': return { isUrlAbsolute: function (u) { return /^https?:\/\//.test(u); } };
    case '@libs/defaultCover': return { defaultCover: 'https://placehold.co/300x400' };
    case '@libs/storage': return { storage: { get: function () {}, set: function () {} }, localStorage: {}, sessionStorage: {} };
    case '@libs/filterInputs': return { FilterTypes: {} };
    default: throw new Error('unknown module: ' + name);
  }
}

globalThis.__lnplugins = globalThis.__lnplugins || {};

// Loads a CommonJS plugin source, stores the instance in __lnplugins[id],
// returns its `name` (or throws if it has no default export).
globalThis.__loadPlugin = function (id, src) {
  var module = { exports: {} };
  var fn = new Function('module', 'exports', 'require', src);
  fn(module, module.exports, __require);
  var plugin = module.exports.default;
  if (!plugin) throw new Error('NO_DEFAULT_EXPORT');
  globalThis.__lnplugins[id] = plugin;
  return plugin.name || id;
};

// Invokes plugin[method](...args) and resolves to a JSON string of the
// result (JSON.stringify(null) for undefined, so the Dart side always gets
// valid JSON to decode).
globalThis.__callPlugin = function (pluginId, method, argsJson) {
  var plugin = globalThis.__lnplugins[pluginId];
  if (!plugin) return Promise.reject(new Error('unknown plugin: ' + pluginId));
  var fn = plugin[method];
  if (typeof fn !== 'function') return Promise.reject(new Error('unknown method: ' + method));
  var args = JSON.parse(argsJson);
  return Promise.resolve(fn.apply(plugin, args)).then(function (r) {
    return JSON.stringify(r === undefined ? null : r);
  });
};

// Evicts a loaded plugin so a later __loadPlugin() with different source
// isn't shadowed by the old instance.
globalThis.__unloadPlugin = function (id) {
  if (globalThis.__lnplugins) delete globalThis.__lnplugins[id];
};

// Plugin metadata for the Dart side (default filters, site, etc).
globalThis.__pluginInfo = function (pluginId) {
  var plugin = globalThis.__lnplugins[pluginId];
  if (!plugin) throw new Error('unknown plugin: ' + pluginId);
  return JSON.stringify({
    name: plugin.name,
    site: plugin.site,
    version: plugin.version,
    filters: plugin.filters,
  });
};
