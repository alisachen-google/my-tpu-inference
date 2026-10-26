// Milestone 3 guide, section persistence and offline export on an owned preview.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || '/dev/shm/alisachen-site-runtime/qa/node_modules/playwright');
const origin = process.env.DESIGN_DOC_TEST_ORIGIN || 'http://127.0.0.1:5187';
if (!['localhost', '127.0.0.1'].includes(new URL(origin).hostname)) throw new Error('Local preview only.');
const site = process.env.DESIGN_DOC_SITE_ROOT;
if (!site) throw new Error('Set DESIGN_DOC_SITE_ROOT.');
const output = process.env.DESIGN_DOC_QA_OUTPUT || '/home/alisachen_google_com/pd_disagg/results/milestone3-doc-review';
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
      await page.goto(`${origin}/signin-with-chatgpt?return_to=${encodeURIComponent('/?section=milestone-recall')}`, { waitUntil: 'networkidle' });
      await page.locator('.composer-footer').getByText(/Commenting as/).waitFor({ state: 'attached' });
      const doc = page.frameLocator('iframe');
      const chapter = doc.locator('#milestone-recall');
      await chapter.getByRole('heading', { name: /Bring the prefix back/ }).waitFor();
      assert.equal(await chapter.locator('.swa-code-map details').count(), 6);
      assert.equal(await chapter.locator('img').count(), 2);
      for (const image of await chapter.locator('img').all()) assert.equal(await image.evaluate(node => node.complete && node.naturalWidth > 0), true);
      const links = chapter.locator('a[href*="/blob/"]');
      assert.ok(await links.count() >= 15);
      for (const link of await links.all()) assert.match(await link.getAttribute('href'), /blob\/9d9c2d89e0e5a1009de44d383892efb0b035e5fc\//);
      for (const [scenario, memory] of [['commit', /Committed tree pin/], ['local', /No new remote-write/], ['reserve', /Rollback allocations/], ['abort', /Deferred destination ownership/], ['receive', /Pending plan retains/]]) {
        await chapter.locator(`[data-m3-case="${scenario}"]`).click();
        assert.match(await chapter.locator('#m3-memory-state').textContent(), memory);
        assert.equal(await chapter.locator(`[data-m3-case="${scenario}"]`).getAttribute('aria-pressed'), 'true');
      }
      const frame = page.frames().find(item => item.url().includes('/document/index.html'));
      assert.equal(await frame.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await chapter.getByRole('button', { name: 'Ask a question', exact: true }).click();
      assert.equal(await page.locator('.composer-section select').inputValue(), 'milestone-recall');
      const question = `LOCAL QA ${name} ${Date.now()}: Why must a recalled prefix remain pinned until admission?`;
      await page.locator('#new-thread-body').fill(question);
      const posted = page.waitForResponse(response => response.url() === `${origin}/api/discussion` && response.request().method() === 'POST');
      await page.getByRole('button', { name: /Post question/ }).click();
      const response = await posted;
      assert.equal(response.status(), 201);
      const saved = await response.json();
      assert.equal(saved.thread.sectionId, 'milestone-recall');
      await page.reload({ waitUntil: 'networkidle' });
      const discussions = await (await context.request.get(`${origin}/api/discussion`)).json();
      assert.ok(discussions.threads.some(item => item.id === saved.thread.id && item.messages[0].body === question));
      const rpc = await context.request.post(`${origin}/mcp`, { data: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_design_document', arguments: {} } } });
      assert.match(JSON.parse((await rpc.json()).result.content[0].text).document, /Bring the prefix back/);
      await page.goto(`${origin}/document/index.html#milestone-recall`, { waitUntil: 'networkidle' });
      await page.locator('#milestone-recall').getByRole('heading', { name: /Bring the prefix back/ }).scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(output, `${name}-chapter.png`) });
      await page.locator('#milestone-recall .technical-figure').first().scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(output, `${name}-architecture.png`) });
      await page.locator('.m3-explorer').scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(output, `${name}-ownership.png`) });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      assert.deepEqual(errors, []);
      results.push({ name, passed: true, page_errors: errors });
      await context.close();
    }
    const context = await browser.newContext({ offline: true });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(`file://${path.resolve(site, 'public/document/spillover-design.html')}`, { waitUntil: 'load' });
    assert.equal(await page.locator('#milestone-recall svg.technical-inline').count(), 2);
    await page.locator('[data-m3-case="abort"]').click();
    assert.match(await page.locator('#m3-memory-state').textContent(), /Deferred destination/);
    const ids = await page.locator('[id]').evaluateAll(nodes => nodes.map(node => node.id));
    assert.equal(ids.length, new Set(ids).size);
    assert.equal(await page.locator('script[src],link[rel=stylesheet],img').count(), 0);
    assert.deepEqual(errors, []);
    results.push({ name: 'offline-export', passed: true, page_errors: errors });
    await context.close();
    fs.writeFileSync(path.join(output, 'browser-qa.json'), JSON.stringify(results, null, 2) + '\n');
    console.log(JSON.stringify(results));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
