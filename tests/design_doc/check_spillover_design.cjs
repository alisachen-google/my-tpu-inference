// Content, calculator, offline export and comment integration for the full design.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || '/dev/shm/alisachen-site-runtime/qa/node_modules/playwright');
const origin = process.env.DESIGN_DOC_TEST_ORIGIN || 'http://127.0.0.1:5187';
if (!['localhost', '127.0.0.1'].includes(new URL(origin).hostname)) throw new Error('Local preview only.');
const site = process.env.DESIGN_DOC_SITE_ROOT;
if (!site) throw new Error('Set DESIGN_DOC_SITE_ROOT to the Sites checkout.');
const output = process.env.DESIGN_DOC_QA_OUTPUT || '/home/alisachen_google_com/pd_disagg/results/spillover-design-review';
fs.mkdirSync(output, { recursive: true });

(async () => {
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const results = [];
  try {
    for (const [name, viewport] of [['desktop', { width: 1512, height: 1000 }], ['mobile', { width: 390, height: 844 }]]) {
      const context = await browser.newContext({ viewport });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.goto(`${origin}/signin-with-chatgpt?return_to=/`, { waitUntil: 'networkidle' });
      await page.locator('.composer-footer').getByText(/Commenting as/).waitFor({ state: 'attached' });
      const doc = page.frameLocator('iframe');
      await doc.locator('#design-brief h2').waitFor();
      for (const section of ['design-brief', 'native-contract', 'phase-guide', 'workload-impact']) {
        assert.equal(await doc.locator(`#${section}`).count(), 1);
        const response = await context.request.post(`${origin}/api/discussion`, { headers: { Origin: origin }, data: {
          action: 'create', requestId: randomUUID(), sectionId: section, kind: 'comment',
          body: `LOCAL QA ${name}: Section ${section} accepts saved review context.`,
        } });
        assert.equal(response.status(), 201);
        assert.equal((await response.json()).thread.sectionId, section);
      }
      assert.equal(await doc.locator('.phase-card').count(), 5);
      for (const image of await doc.locator('#phase-guide img').all()) {
        assert.equal(await image.evaluate(node => node.complete && node.naturalWidth > 0), true);
      }
      assert.equal(await doc.locator('#perf-before-ms').textContent(), '409.6 ms');
      assert.equal(await doc.locator('#perf-after-ms').textContent(), '290.3 ms');
      assert.equal(await doc.locator('#perf-savings-result').textContent(), '+33.8 ms');
      await doc.locator('#perf-reuse').fill('0');
      await doc.locator('#perf-tax').fill('0');
      assert.equal(await doc.locator('#perf-savings-result').textContent(), '+0.0 ms');
      assert.equal(await doc.locator('#perf-tokens-result').textContent(), '0');
      await doc.locator('#perf-reuse').fill('100');
      await doc.locator('#perf-overhead').fill('1000');
      assert.match(await doc.locator('#perf-savings-result').textContent(), /^−/);
      assert.match(await doc.locator('#perf-verdict').textContent(), /does not guarantee/);
      await doc.locator('#perf-overhead').fill('80');
      await doc.locator('#perf-reuse').fill('40');
      await doc.locator('#perf-tax').fill('2');
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      const frame = page.frames().find(item => item.url().includes('/document/index.html'));
      assert.equal(await frame.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      const rpc = await context.request.post(`${origin}/mcp`, { data: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_design_document', arguments: {} } } });
      assert.match(JSON.parse((await rpc.json()).result.content[0].text).document, /modeled|cost model/i);
      await page.goto(`${origin}/document/index.html#phase-guide`, { waitUntil: 'networkidle' });
      await page.locator('.technical-figure').first().scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(output, `${name}-spill-sequence.png`) });
      await page.locator('#perf-lab').scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(output, `${name}-performance.png`) });
      assert.deepEqual(errors, []);
      results.push({ name, passed: true, page_errors: errors });
      await context.close();
    }
    const offline = await browser.newContext({ offline: true });
    const page = await offline.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(`file://${path.resolve(site, 'public/document/spillover-design.html')}`, { waitUntil: 'load' });
    assert.equal(await page.locator('#phase-guide svg.technical-inline').count(), 2);
    assert.equal(await page.locator('#perf-savings-result').textContent(), '+33.8 ms');
    await page.locator('#perf-reuse').fill('0');
    assert.equal(await page.locator('#perf-tokens-result').textContent(), '0');
    assert.equal(await page.locator('script[src],link[rel=stylesheet],img').count(), 0);
    assert.deepEqual(errors, []);
    results.push({ name: 'offline-export', passed: true, page_errors: errors });
    await offline.close();
    fs.writeFileSync(path.join(output, 'browser-qa.json'), JSON.stringify(results, null, 2) + '\n');
    console.log(JSON.stringify(results));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
