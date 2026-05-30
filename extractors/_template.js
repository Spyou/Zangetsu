// WATCH_APP extractor template. Copy to <host>.js, fill in extract().
// getInfo().hosts lists every domain this extractor claims; the runtime
// registers it under each one and routes extractVideo(url) by URL host.

function getInfo() {
  return { id: 'myhost', name: 'MyHost', version: '1.0.0',
           hosts: ['myhost.com', 'myhost.to'] };
}

function extract(url, opts) {
  // Resolve the embed page to one or more playable VideoSource objects.
  // return [{ url, quality, container:'hls'|'mp4', headers, kind:'sub'|'dub',
  //           audioLang, subtitles:[{url,lang,label,format,default}] }]
  return [];
}
