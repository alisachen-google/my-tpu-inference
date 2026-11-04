// Milestone 2 content and comment integration, against an owned local D1 preview.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || '/dev/shm/alisachen-site-runtime/qa/node_modules/playwright');
const origin = process.env.DESIGN_DOC_TEST_ORIGIN || 'http://127.0.0.1:5187';
if (!['localhost', '127.0.0.1'].includes(new URL(origin).hostname)) throw new Error('Local preview only.');
const output = process.env.DESIGN_DOC_QA_OUTPUT || '/home/alisachen_google_com/pd_disagg/results/milestone-swa-doc-review';
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
      await page.goto(`${origin}/signin-with-chatgpt?return_to=${encodeURIComponent('/?section=milestone-swa')}`, { waitUntil: 'networkidle' });
      await page.locator('.composer-footer').getByText(/Commenting as/).waitFor({ state: 'attached' });
      const doc = page.frameLocator('iframe');
      const chapter = doc.locator('#milestone-swa');
      await chapter.getByRole('heading', { name: /Two pools/ }).waitFor();
      assert.equal(await chapter.locator('.swa-code-map details').count(), 5);
      assert.equal(await chapter.locator('a[data-swa-source]').count(), 7);
      for (const link of await chapter.locator('a[data-swa-source]').all()) {
        assert.match(await link.getAttribute('href'), /blob\/bbc4b298e12be849427f4f2d5254451abe376013\//);
      }
      for (const [scenario, decision] of [['ready', 'publish when all ranks agree'], ['partial', 'drain FULL first'], ['timeout', 'retain landings'], ['waiting', 'retain landings']]) {
        await chapter.locator(`[data-swa-case="${scenario}"]`).click();
        assert.equal(await chapter.locator('#swa-gate-state').textContent(), decision);
        assert.equal(await chapter.locator(`[data-swa-case="${scenario}"]`).getAttribute('aria-pressed'), 'true');
      }
      const frame = page.frames().find(item => item.url().includes('/document/index.html'));
      assert.equal(await frame.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await chapter.getByRole('button', { name: 'Ask a question', exact: true }).click();
      assert.equal(await page.locator('.composer-section select').inputValue(), 'milestone-swa');
      await page.locator('#new-thread-body').fill(`LOCAL QA ${name} ${Date.now()}: Why does a failed SWA transfer retain the FULL landing?`);
      const posted = page.waitForResponse(response => response.url() === `${origin}/api/discussion` && response.request().method() === 'POST');
      await page.getByRole('button', { name: /Post question/ }).click();
      const response = await posted;
      assert.equal(response.status(), 201);
      const saved = await response.json();
      assert.equal(saved.thread.sectionId, 'milestone-swa');
      const rpc = await context.request.post(`${origin}/mcp`, { data: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_design_document', arguments: {} } } });
      const rpcBody = await rpc.json();
      assert.equal(rpcBody.result.isError, false);
      assert.match(JSON.parse(rpcBody.result.content[0].text).document, /Two pools\. One complete prefix/);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await page.goto(`${origin}/document/index.html#milestone-swa`, { waitUntil: 'networkidle' });
      await page.locator('.swa-architecture').scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(output, `${name}-architecture.png`) });
      await page.locator('.swa-gate').scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(output, `${name}-completion.png`) });
      assert.deepEqual(errors, []);
      results.push({ name, passed: true, page_errors: errors, local_thread: saved.thread.id });
      await context.close();
    }
    fs.writeFileSync(path.join(output, 'browser-qa.json'), JSON.stringify(results, null, 2) + '\n');
    console.log(JSON.stringify(results));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
