import { Buffer } from 'buffer';
globalThis.Buffer = Buffer;
if (!globalThis.process) globalThis.process = { env: {}, nextTick: function (f) { Promise.resolve().then(f); } };
globalThis.global = globalThis;
if (!globalThis.atob) globalThis.atob = function (b64) { return Buffer.from(String(b64), 'base64').toString('binary'); };
if (!globalThis.btoa) globalThis.btoa = function (s) { return Buffer.from(String(s), 'binary').toString('base64'); };
if (!globalThis.URL) {
  globalThis.URL = function URL(url, base) {
    var u = String(url);
    if (base && !/^[a-z][a-z0-9+.-]*:\/\//i.test(u)) {
      var b = String(base);
      var root = (b.match(/^([a-z]+:\/\/[^\/]+)/i) || [b])[0];
      if (u.charAt(0) === '/') u = root + u;
      else u = b.replace(/\/[^\/]*$/, '/') + u;
    }
    var m = u.match(/^([a-z][a-z0-9+.-]*:)\/\/([^\/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/i) || [];
    this.href = u;
    this.protocol = m[1] || '';
    this.host = m[2] || '';
    this.hostname = (m[2] || '').split(':')[0];
    this.port = ((m[2] || '').split(':')[1]) || '';
    this.pathname = m[3] || '/';
    this.search = m[4] || '';
    this.hash = m[5] || '';
    this.origin = (m[1] || '') + '//' + (m[2] || '');
  };
  globalThis.URL.prototype.toString = function () { return this.href; };
}
if (!globalThis.URLSearchParams) {
  globalThis.URLSearchParams = function URLSearchParams(init) {
    this._p = [];
    var self = this;
    if (typeof init === 'string') {
      init.replace(/^\?/, '').split('&').forEach(function (pair) {
        if (!pair) return;
        var i = pair.indexOf('=');
        var k = i < 0 ? pair : pair.slice(0, i), v = i < 0 ? '' : pair.slice(i + 1);
        self._p.push([decodeURIComponent(k), decodeURIComponent(v.replace(/\+/g, ' '))]);
      });
    } else if (init && typeof init === 'object') {
      Object.keys(init).forEach(function (k) { self._p.push([k, String(init[k])]); });
    }
  };
  var P = globalThis.URLSearchParams.prototype;
  P.append = function (k, v) { this._p.push([String(k), String(v)]); };
  P.set = function (k, v) { this.delete(k); this._p.push([String(k), String(v)]); };
  P.get = function (k) { for (var i = 0; i < this._p.length; i++) if (this._p[i][0] === k) return this._p[i][1]; return null; };
  P.getAll = function (k) { return this._p.filter(function (x) { return x[0] === k; }).map(function (x) { return x[1]; }); };
  P.has = function (k) { return this.get(k) !== null; };
  P.delete = function (k) { this._p = this._p.filter(function (x) { return x[0] !== k; }); };
  P.forEach = function (cb) { this._p.forEach(function (x) { cb(x[1], x[0]); }); };
  P.toString = function () { return this._p.map(function (x) { return encodeURIComponent(x[0]) + '=' + encodeURIComponent(x[1]); }).join('&'); };
}
