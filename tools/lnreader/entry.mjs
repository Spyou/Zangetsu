import * as cheerio from 'cheerio/slim';
import * as htmlparser2 from 'htmlparser2';
import dayjs from 'dayjs';
import customParseFormat from 'dayjs/plugin/customParseFormat.js';
import relativeTime from 'dayjs/plugin/relativeTime.js';
import utc from 'dayjs/plugin/utc.js';

// Pre-extend the plugins LNReader ships, so plugins that do dayjs(str, format)
// or .fromNow() work like they do in the real LNReader app.
dayjs.extend(customParseFormat);
dayjs.extend(relativeTime);
dayjs.extend(utc);

globalThis.__cheerio = cheerio;
globalThis.__htmlparser2 = htmlparser2;
globalThis.loadCheerio = cheerio.load;
globalThis.__dayjs = dayjs;
