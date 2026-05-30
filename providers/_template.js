// WATCH_APP provider template. Copy to <id>.js, fill in the functions.
// The host gives you: fetch(url,opts)->{status,body,headers,json,text},
// extractVideo(embedUrl,opts)->[VideoSource], htmlText(), absUrl(), console.

var SOURCE_ID = 'mysource';
var SITE = 'https://example.com';

function getInfo() {
  return { name: 'My Source', lang: 'en', baseUrl: SITE,
           logo: SITE + '/favicon.ico', type: 'anime', version: '1.0.0' };
}

function search(query, page, opts) {
  // return [{ id, title, url, cover, coverHeaders?, type:'anime', sourceId: SOURCE_ID }]
  return [];
}

function getDetail(url) {
  // return { id, title, url, cover?, description?, status, genres:[], studios:[],
  //          type:'anime', sourceId: SOURCE_ID, episodes:[Episode] }
  return null;
}

function getEpisodes(seriesUrl) {
  // Optional if getDetail already returns episodes. return [Episode].
  return [];
}

function getVideoSources(episodeUrl) {
  // return [VideoSource], OR resolve an embed via extractVideo():
  //   return extractVideo('https://embed.host/v/ID', { headers: { Referer: SITE + '/' } });
  return [];
}
