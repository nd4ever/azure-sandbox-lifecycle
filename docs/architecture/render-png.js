#!/usr/bin/env node
/**
 * Render an HTML diagram to PNG using the installed Microsoft Edge via puppeteer-core.
 * Usage: node render-png.js <input.html> <output.png>
 * Install deps first:  npm install puppeteer-core
 */
const puppeteer = require('puppeteer-core');
const fs = require('fs');

const EDGE_CANDIDATES = [
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
];

(async () => {
  const input = process.argv[2];
  const output = process.argv[3];
  if (!input || !output) {
    console.error('Usage: node render-png.js <input.html> <output.png>');
    process.exit(1);
  }
  const edge = EDGE_CANDIDATES.find(p => fs.existsSync(p));
  if (!edge) { console.error('Microsoft Edge not found.'); process.exit(1); }

  const browser = await puppeteer.launch({
    executablePath: edge,
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-gpu', '--hide-scrollbars'],
    userDataDir: require('os').tmpdir() + '\\edge-diagram-profile-' + Date.now(),
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1560, height: 1120, deviceScaleFactor: 2 });
  await page.goto('file:///' + input.replace(/\\/g, '/'), { waitUntil: 'networkidle0' });
  await new Promise(r => setTimeout(r, 1500));
  const body = await page.$('body');
  const box = await body.boundingBox();
  await page.screenshot({ path: output, clip: { x: 0, y: 0, width: Math.ceil(box.width), height: Math.ceil(box.height) } });
  await browser.close();
  console.log('OK ' + output);
})();
