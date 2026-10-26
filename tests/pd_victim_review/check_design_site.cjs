// Browser QA for the design explanation; kept outside the SGLang feature.
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const assert = require('node:assert/strict');

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, all) => {
  if (index % 2 === 0) pairs.push([value.replace(/^--/, ''), all[index + 1]]);
  return pairs;
}, []));
if (!args['site-root'] || !args['playwright-module'] || !args.output) {
  throw new Error('Usage: node check_design_site.cjs --site-root /site/dist --playwright-module /node_modules/playwright --output /results');
}
const siteRoot = path.resolve(args['site-root']);
const out = path.resolve(args.output);
fs.mkdirSync(out, { recursive: true });
const { chromium } = require(path.resolve(args['playwright-module']));
const contentTypes = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.json': 'application/json', '.patch': 'text/plain' };
const server = http.createServer((req, res) => {
  const name = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  const file = path.resolve(siteRoot, '.' + (name === '/' ? '/index.html' : name));
  if (!file.startsWith(siteRoot + path.sep)) { res.writeHead(403).end(); return; }
  try {
    res.writeHead(200, { 'Content-Type': contentTypes[path.extname(file)] || 'application/octet-stream' });
    res.end(fs.readFileSync(file));
  } catch { res.writeHead(404).end(); }
});

(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const result = [];
  try {
    for (const [name, viewport] of [['desktop', { width: 1440, height: 1000 }], ['mobile', { width: 390, height: 844 }]]) {
      const page = await browser.newPage({ viewport });
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      page.on('response', response => { if (response.status() >= 400) errors.push(`${response.status()} ${response.url()}`); });
      await page.goto(`http://127.0.0.1:${server.address().port}/`, { waitUntil: 'networkidle' });
      assert.match(await page.title(), /Decode DRAM/);
      assert.equal(await page.locator('.finding').count(), 4);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `${name}: document overflows viewport`);
      await page.screenshot({ path: path.join(out, `${name}-hero.png`) });
      if (name === 'mobile') {
        assert.equal(await page.locator('.diagram-hint').isVisible(), true);
        await page.locator('.diagram-scroll').evaluate(node => { node.scrollLeft = node.scrollWidth; });
        assert.equal(await page.locator('.diagram-scroll').evaluate(node => node.scrollLeft > 0), true);
        await page.locator('.diagram-scroll').evaluate(node => { node.scrollLeft = 0; });
      }
      await page.getByRole('button', { name: 'Prefix recall', exact: true }).click();
      assert.match(await page.locator('#path-title').textContent(), /HBM/);
      assert.equal(await page.locator('#recall-routes').evaluate(node => !node.classList.contains('hidden')), true);
      await page.getByRole('button', { name: 'Earlier v3 path', exact: true }).click();
      assert.match(await page.locator('#path-expression').textContent(), /P DRAM/);
      await page.getByRole('button', { name: 'Host spill', exact: true }).click();
      assert.equal(await page.locator('#path-expression').textContent(), 'Prefill DRAM → network → Decode DRAM');
      await page.getByRole('button', { name: 'Try an incomplete SWA tail', exact: true }).click();
      assert.match(await page.locator('#reuse-status').textContent(), /Hold publication/);
      await page.getByRole('button', { name: 'Restore the matching SWA tail', exact: true }).click();
      await page.locator('#prefix-length').fill('1024');
      assert.equal(await page.locator('#swa-window').textContent(), '[896, 1,024)');
      await page.locator('.life-step[data-step="3"]').click();
      assert.match(await page.locator('#step-title').textContent(), /Terminal native/);
      await page.locator('.code-tab[data-code="anchor"]').click();
      assert.match(await page.locator('#code-snippet').textContent(), /_send_reads/);
      await page.locator('.code-tab[data-code="wrapper"]').click();
      assert.match(await page.locator('#code-snippet').textContent(), /local_control_port/);
      await page.locator('.code-tab[data-code="spill"]').click();
      await page.screenshot({ path: path.join(out, `${name}-full.png`), fullPage: true });
      await page.locator('#memory-map').scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(out, `${name}-diagram.png`) });
      assert.deepEqual(errors, [], `${name}: browser errors`);
      result.push({ name, viewport, console_errors: errors, checks_passed: 14 });
      await page.close();
    }
    fs.writeFileSync(path.join(out, 'browser-qa.json'), JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify(result));
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
