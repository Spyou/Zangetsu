import * as cheerio from 'cheerio/slim';
import * as htmlparser2 from 'htmlparser2';
globalThis.__cheerio = cheerio;
globalThis.__htmlparser2 = htmlparser2;
globalThis.loadCheerio = cheerio.load;
