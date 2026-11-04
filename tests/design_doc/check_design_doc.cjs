// End-to-end checks against an owned local preview and its real local D1 DB.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || '/dev/shm/alisachen-site-runtime/qa/node_modules/playwright');
const origin = process.env.DESIGN_DOC_TEST_ORIGIN || 'http://127.0.0.1:5187';
if (!['127.0.0.1', 'localhost'].includes(new URL(origin).hostname)) throw new Error('Local preview only.');
const output = process.env.DESIGN_DOC_QA_OUTPUT || '/home/alisachen_google_com/pd_disagg/results/design-doc-review';
fs.mkdirSync(output,{recursive:true});

(async()=>{
  const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
  const results=[];
  try {
    for(const [name,viewport] of [['desktop',{width:1512,height:1000}],['mobile',{width:390,height:844}]]) {
      const context=await browser.newContext({viewport});
      const page=await context.newPage();
      const errors=[];
      page.on('pageerror',error=>errors.push(error.message));
      const anonymous=await context.request.get(`${origin}/api/discussion`);
      assert.equal(anonymous.status(),401);
      await page.goto(`${origin}/signin-with-chatgpt?return_to=/`,{waitUntil:'networkidle'});
      await page.locator('.composer-footer').getByText(/Commenting as/).waitFor({state:"attached"});
      assert.equal(await page.locator('h1').textContent(),'P/D victim prefix cache');
      assert.equal(await page.locator('.ai-status').getByText('Automatic replies need an AI connection').count(),1);
      const doc=page.frameLocator('iframe');
      await doc.locator('#memory-svg').waitFor();
      if(name==='mobile') await page.getByRole('button',{name:/^Discussion/}).click();
      const question=`LOCAL QA ${name} ${Date.now()}: Why must FULL and SWA end at the same token?`;
      await page.locator('#new-thread-body').fill(question);
      const posted=page.waitForResponse(response=>response.url()===`${origin}/api/discussion` && response.request().method()==='POST');
      await page.getByRole('button',{name:/Post question/}).click();
      const response=await posted;
      assert.equal(response.status(),201);
      const saved=await response.json();
      assert.equal(saved.thread.messages[0].body,question);
      assert.equal(saved.thread.messages[0].role,'user');
      assert.equal(saved.ai.available,false);
      await page.locator('.thread-content').getByText(question,{exact:true}).waitFor();
      await page.getByRole('textbox',{name:'Reply to thread'}).fill('LOCAL QA: Keep this follow-up attached to the saved thread.');
      await page.locator('.reply-form button[type=submit]').click();
      await page.locator('.thread-content').getByText('LOCAL QA: Keep this follow-up attached to the saved thread.',{exact:true}).waitFor();
      await page.reload({waitUntil:'networkidle'});
      await page.locator('.composer-footer').getByText(/Commenting as/).waitFor({state:"attached"});
      if(name==='mobile') await page.getByRole('button',{name:/^Discussion/}).click();
      await page.getByRole('button',{name:new RegExp(question.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'))}).click();
      await page.getByRole('button',{name:'Resolve thread',exact:true}).click();
      await page.getByRole('button',{name:'All',exact:true}).click();
      const threadCard=page.locator('.thread-card').filter({hasText:question});
      // The CSS class may change; the exact summary is the stable interaction.
      const summary=page.getByRole('button',{name:new RegExp(question.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'))});
      if(await summary.getAttribute('aria-expanded')!=='true') await summary.click();
      await page.getByRole('button',{name:'Reopen thread',exact:true}).click();
      const forbidden=await context.request.post(`${origin}/api/discussion`,{data:{action:'create'},headers:{Origin:'https://other.example'}});
      assert.equal(forbidden.status(),403);
      const rpc=await context.request.post(`${origin}/mcp`,{data:{jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'get_design_discussion',arguments:{thread_id:saved.thread.id}}}});
      assert.equal(rpc.status(),200);
      const rpcData=await rpc.json();
      assert.equal(rpcData.result.isError,false);
      assert.equal(JSON.parse(rpcData.result.content[0].text).id,saved.thread.id);
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
      await page.screenshot({path:path.join(output,`${name}-discussion.png`),fullPage:true});
      if(name==='mobile') await page.getByRole('button',{name:'Document',exact:true}).click();
      await page.screenshot({path:path.join(output,`${name}-document.png`),fullPage:true});
      assert.deepEqual(errors,[]);
      results.push({name,passed:true,thread:saved.thread.id,page_errors:errors});
      await context.close();
    }
    fs.writeFileSync(path.join(output,'browser-qa.json'),JSON.stringify(results,null,2)+'\n');
    console.log(JSON.stringify(results));
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
