#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
npm install
npx esbuild entry.mjs --bundle --format=iife --target=es2019 --inject:./shim.mjs \
  --outfile=../../assets/js/lnreader_cheerio.js
