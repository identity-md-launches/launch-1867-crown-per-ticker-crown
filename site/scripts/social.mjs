import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from '/opt/imd-tools/playwright-mcp/node_modules/playwright/index.mjs';

// Rasterize the repository-native social SVG for social crawlers that require PNG.
const site = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  await page.setContent(`<html><body style="margin:0">${await readFile(resolve(site, 'design/social.svg'), 'utf8')}</body></html>`);
  await page.screenshot({ path: resolve(site, 'public/social.png') });
} finally { await browser.close(); }
