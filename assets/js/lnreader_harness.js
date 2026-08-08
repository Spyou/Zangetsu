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
function __rawFetch(url, init) {
  return new Promise(function (resolve, reject) {
    var id = ++globalThis.__fetchSeq;
    globalThis.__pendingFetch[id] = { resolve: resolve, reject: reject };
    globalThis.__outbox.push({ id: id, url: String(url), init: init || {} });
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
