import * as cheerio from 'cheerio/slim';
import * as htmlparser2 from 'htmlparser2';
import dayjs from 'dayjs';
import customParseFormat from 'dayjs/plugin/customParseFormat.js';
import relativeTime from 'dayjs/plugin/relativeTime.js';
import utc from 'dayjs/plugin/utc.js';
// AES-GCM for the handful of plugins that decrypt their payloads (WTR-LAB).
// Same library the real LNReader uses for @libs/aes — hand-rolling a block
// cipher here would be the wrong kind of clever.
import { gcm } from '@noble/ciphers/aes.js';

// Pre-extend the plugins LNReader ships, so plugins that do dayjs(str, format)
// or .fromNow() work like they do in the real LNReader app.
dayjs.extend(customParseFormat);
dayjs.extend(relativeTime);
dayjs.extend(utc);

globalThis.__cheerio = cheerio;
globalThis.__htmlparser2 = htmlparser2;
globalThis.loadCheerio = cheerio.load;
globalThis.__dayjs = dayjs;
globalThis.__aesGcm = gcm;
