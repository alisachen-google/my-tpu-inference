// PR 1789 overview, download and discussion checks against an owned local Site.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || '/dev/shm/alisachen-site-runtime/qa/node_modules/playwright');
const origin = process.env.DESIGN_DOC_TEST_ORIGIN || 'http://127.0.0.1:5187';
if (!['127.0.0.1', 'localhost'].includes(new URL(origin).hostname)) throw new Error('Local preview only.');
const site = process.env.DESIGN_DOC_SITE_ROOT;
if (!site) throw new Error('Set DESIGN_DOC_SITE_ROOT.');
const output = process.env.DESIGN_DOC_QA_OUTPUT || '/home/alisachen_google_com/pd_disagg/results/pr1789-diagram-review';
fs.mkdirSync(output, { recursive: true });

async function modes(doc) {
  assert.equal(await doc.locator('#memory-map #memory-svg').count(), 1);
  await doc.getByRole('button', { name: 'Both paths', exact: true }).click();
  for (const id of ['spill-routes', 'recall-routes']) {
    assert.equal(await doc.locator(`#${id}`).evaluate(node => !node.classList.contains('hidden')), true);
  }
  assert.equal(await doc.locator('#path-expression').textContent(), 'Prefill DRAM ⇄ network ⇄ Decode DRAM');
  await doc.getByRole('button', { name: '1 · Spillover', exact: true }).click();
  assert.equal(await doc.locator('#recall-routes').evaluate(node => node.classList.contains('hidden')), true);
  assert.match(await doc.locator('#native-roles').textContent(), /Producer: Prefill.*Consumer: Decode/);
  await doc.getByRole('button', { name: '2 · Recall', exact: true }).click();
  assert.equal(await doc.locator('#spill-routes').evaluate(node => node.classList.contains('hidden')), true);
  assert.match(await doc.locator('#path-expression').textContent(), /Decode DRAM → network → Prefill DRAM → H2D at admission → Prefill HBM/);
  assert.match(await doc.locator('#native-roles').textContent(), /Producer: Decode.*Consumer: Prefill/);
  assert.match(await doc.locator('#path-copy').textContent(), /source="host".*destination="host"/);
  await doc.getByRole('button', { name: 'Both paths', exact: true }).click();
  await doc.locator('#motion-toggle').click();
  assert.equal(await doc.locator('#memory-svg').evaluate(node => node.classList.contains('paused')), true);
  await doc.locator('#motion-toggle').click();
  assert.equal(await doc.locator('#memory-svg').evaluate(node => node.classList.contains('paused')), false);
}

(async () => {
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const results = [];
  try {
    for (const [name, viewport] of [['desktop', { width: 1512, height: 1100 }], ['mobile', { width: 390, height: 844 }]]) {
      const context = await browser.newContext({ viewport });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.goto(`${origin}/signin-with-chatgpt?return_to=${encodeURIComponent('/?section=memory-map')}`, { waitUntil: 'networkidle' });
      await page.locator('.composer-footer').getByText(/Commenting as/).waitFor({ state: 'attached' });
      const doc = page.frameLocator('iframe');
      await doc.locator('#memory-svg').waitFor();
      await modes(doc);
      assert.equal(await doc.locator('#memory-map a[href="https://github.com/sgl-project/sglang-torchtpu/pull/1789"]').count(), 1);
      assert.equal(await doc.locator('#memory-map a[href*="c910830c0e5962ec07f215ed1fec814e9b5dc323"]').count(), 1);
      assert.match(await doc.locator('.pr-example').textContent(), /32 FULL pages \+ 2 SWA pages/);
      assert.match(await doc.locator('.pr-native-card').textContent(), /local_host_block_ids=pages/);
      assert.match(await doc.locator('.pr-enable').textContent(), /SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1/);
      assert.equal(await doc.locator('#milestone-recall a[href*="9d9c2d89"]').count() > 0, true);
      const svg = await context.request.get(`${origin}/document/pr1789-overview.svg`);
      assert.equal(svg.status(), 200);
      assert.match(await svg.text(), /destination="host"/);
      const response = await context.request.post(`${origin}/api/discussion`, {
        headers: { Origin: origin }, data: {
          action: 'create', requestId: randomUUID(), sectionId: 'memory-map', kind: 'question',
          body: `LOCAL QA ${name}: Why does PR 1789 recall into Prefill DRAM before HBM admission?`,
        },
      });
      assert.equal(response.status(), 201);
      assert.equal((await response.json()).thread.sectionId, 'memory-map');
      const rpc = await context.request.post(`${origin}/mcp`, { data: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_design_document', arguments: {} } } });
      const document = JSON.parse((await rpc.json()).result.content[0].text).document;
      assert.match(document, /c910830c0e5962ec07f215ed1fec814e9b5dc323/);
      assert.match(document, /BOTH Prefill DRAM to Decode DRAM spillover and Decode DRAM to Prefill DRAM recall/);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      const frame = page.frames().find(frame => frame.url().includes('/document/index.html'));
      assert.equal(await frame.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      if (name === 'mobile') {
        await doc.locator('.diagram-scroll').evaluate(node => { node.scrollLeft = node.scrollWidth; });
        assert.equal(await doc.locator('.diagram-scroll').evaluate(node => node.scrollLeft > 0), true);
        await doc.locator('.diagram-scroll').evaluate(node => { node.scrollLeft = 0; });
      }
      await page.goto(`${origin}/document/index.html#memory-map`, { waitUntil: 'networkidle' });
      await page.locator('#memory-map').scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(output, `${name}-overview.png`) });
      await page.locator('.pr-focus-grid').scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(output, `${name}-full-swa-native-api.png`) });
      assert.deepEqual(errors, []);
      results.push({ name, passed: true, page_errors: errors });
      await context.close();
    }
    const offline = await browser.newContext({ offline: true });
    const page = await offline.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(`file://${path.resolve(site, 'public/document/spillover-design.html')}`, { waitUntil: 'load' });
    await modes(page);
    assert.equal(await page.locator('script[src], link[rel=stylesheet], img').count(), 0);
    const ids = await page.locator('[id]').evaluateAll(nodes => nodes.map(node => node.id));
    assert.equal(ids.length, new Set(ids).size, 'Offline document contains duplicate IDs');
    assert.deepEqual(errors, []);
    results.push({ name: 'offline', passed: true, page_errors: errors });
    await offline.close();
    fs.writeFileSync(path.join(output, 'browser-qa.json'), JSON.stringify(results, null, 2) + '\n');
    console.log(JSON.stringify(results));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
