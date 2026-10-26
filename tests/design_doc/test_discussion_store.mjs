import assert from 'node:assert/strict';
import test from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const siteRoot = process.env.DESIGN_DOC_SITE_ROOT || '/home/alisachen_google_com/sites/pd-victim-cache-design';
const { DiscussionStore, DiscussionError, checkedSection, checkedText } = await import(pathToFileURL(path.join(siteRoot, 'lib/discussion-store.ts')).href);

class LocalStatement {
  constructor(db, sql, values = []) { this.db = db; this.sql = sql; this.values = values; }
  bind(...values) { return new LocalStatement(this.db, this.sql, values); }
  async first() { return this.db.prepare(this.sql).get(...this.values) ?? null; }
  async all() { return { results: this.db.prepare(this.sql).all(...this.values) }; }
  async run() { return this.db.prepare(this.sql).run(...this.values); }
}
class LocalD1 {
  constructor() {
    this.sqlite = new DatabaseSync(':memory:');
    this.sqlite.exec(`
      PRAGMA foreign_keys=ON;
      CREATE TABLE doc_threads (id TEXT PRIMARY KEY, section_id TEXT NOT NULL, quote TEXT,
        kind TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'open', created_by TEXT NOT NULL,
        created_name TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      CREATE TABLE doc_messages (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES doc_threads(id),
        role TEXT NOT NULL, body TEXT NOT NULL, author_id TEXT NOT NULL, author_name TEXT NOT NULL,
        created_at INTEGER NOT NULL, request_id TEXT NOT NULL UNIQUE,
        generation_status TEXT NOT NULL DEFAULT 'complete', generation_error TEXT);
    `);
  }
  prepare(sql) { return new LocalStatement(this.sqlite, sql); }
  async batch(statements) {
    this.sqlite.exec('BEGIN');
    try {
      const results = statements.map(s => this.sqlite.prepare(s.sql).run(...s.values));
      this.sqlite.exec('COMMIT');
      return results;
    } catch (error) { this.sqlite.exec('ROLLBACK'); throw error; }
  }
}
const alice = { userId: 'owner-alice', name: 'Alice' };
const bob = { userId: 'other-bob', name: 'Bob' };
const create = { requestId: 'request-create-1', sectionId: 'architecture', quote: 'Shared scheduler', kind: 'question', body: 'Why keep the source pin?' };
function fixture() { const database = new LocalD1(); return { database, store: new DiscussionStore(database) }; }

test('atomic create is idempotent and preserves quoted section context', async () => {
  const { database, store } = fixture();
  const first = await store.createThread(alice, create);
  const retried = await store.createThread(alice, create);
  assert.equal(first.id, retried.id);
  assert.equal(first.sectionId, 'architecture');
  assert.equal(first.quote, 'Shared scheduler');
  assert.equal(retried.messages.length, 1);
  assert.equal(retried.messages[0].role, 'user');
  assert.equal(database.sqlite.prepare('SELECT COUNT(*) AS n FROM doc_threads').get().n, 1);
  await assert.rejects(store.createThread(alice, { ...create, body: 'Changed question' }), error => error.status === 409);
  await assert.rejects(store.createThread(bob, create), error => error.status === 409);
  assert.equal(database.sqlite.prepare('SELECT COUNT(*) AS n FROM doc_threads').get().n, 1);
});

test('duplicate replies do not duplicate messages or redirect into another thread', async () => {
  const { store } = fixture();
  const first = await store.createThread(alice, create);
  const second = await store.createThread(alice, { ...create, requestId: 'request-create-2' });
  const input = { threadId: first.id, requestId: 'request-reply-1', body: 'And what happens after cancellation?' };
  await store.reply(alice, input);
  const retry = await store.reply(alice, input);
  assert.equal(retry.messages.length, 2);
  await assert.rejects(store.reply(alice, { ...input, threadId: second.id }), error => error.status === 409);
  await assert.rejects(store.reply(bob, input), error => error.status === 409);
});

test('only the thread author can resolve and a resolved thread must be reopened', async () => {
  const { store } = fixture();
  const thread = await store.createThread(alice, create);
  await assert.rejects(store.resolve(bob, thread.id, 'resolved'), error => error.status === 403);
  assert.equal((await store.resolve(alice, thread.id, 'resolved')).status, 'resolved');
  await assert.rejects(store.reply(alice, { threadId: thread.id, requestId: 'request-closed-1', body: 'Follow-up' }), error => error.status === 409);
  await store.resolve(alice, thread.id, 'open');
  assert.equal((await store.reply(alice, { threadId: thread.id, requestId: 'request-closed-1', body: 'Follow-up' })).messages.length, 2);
});

test('assistant job claims suppress duplicate requests and concurrent new asks', async () => {
  const { database, store } = fixture();
  const thread = await store.createThread(alice, create);
  const first = await store.claimAssistantReply(thread.id, 'assistant-request-1');
  assert.equal(first.claimed, true);
  assert.equal((await store.claimAssistantReply(thread.id, 'assistant-request-1')).claimed, false);
  assert.equal((await store.claimAssistantReply(thread.id, 'assistant-request-2')).claimed, false);
  let saved = await store.getThread(thread.id);
  assert.equal(saved.aiStatus, 'pending');
  assert.equal(saved.messages.length, 1, 'pending placeholders must not appear as empty assistant replies');
  assert.equal(database.sqlite.prepare("SELECT COUNT(*) AS n FROM doc_messages WHERE role='assistant'").get().n, 1);
  await store.completeAssistantReply(first.messageId, 'The pin protects the bytes until native completion.');
  saved = await store.getThread(thread.id);
  assert.equal(saved.aiStatus, 'complete');
  assert.deepEqual(saved.messages.map(m => m.role), ['user', 'assistant']);
  assert.equal((await store.claimAssistantReply(thread.id, 'assistant-request-1')).claimed, false);
});

test('AI failure retains the question and allows a new explicit retry', async () => {
  const { store } = fixture();
  const thread = await store.createThread(alice, create);
  const attempt = await store.claimAssistantReply(thread.id, 'assistant-request-1');
  await store.failAssistantReply(attempt.messageId);
  const failed = await store.getThread(thread.id);
  assert.equal(failed.aiStatus, 'failed');
  assert.equal(failed.messages[0].body, create.body);
  assert.equal(failed.messages.length, 1);
  assert.match(failed.aiError, /saved/);
  assert.equal((await store.claimAssistantReply(thread.id, 'assistant-request-1')).claimed, false);
  assert.equal((await store.claimAssistantReply(thread.id, 'assistant-request-2')).claimed, true);
});

test('interrupted jobs become retryable without exposing a stale empty answer', async () => {
  const { database, store } = fixture();
  const thread = await store.createThread(alice, create);
  const old = await store.claimAssistantReply(thread.id, 'assistant-request-1');
  database.sqlite.prepare('UPDATE doc_messages SET created_at=? WHERE id=?').run(Date.now() - 180_000, old.messageId);
  assert.equal((await store.getThread(thread.id)).aiStatus, 'failed');
  const fresh = await store.claimAssistantReply(thread.id, 'assistant-request-2');
  assert.equal(fresh.claimed, true);
  await store.completeAssistantReply(old.messageId, 'Late stale answer');
  assert.equal((await store.getThread(thread.id)).messages.length, 1);
  await store.completeAssistantReply(fresh.messageId, 'Fresh answer');
  const finished = await store.getThread(thread.id);
  assert.equal(finished.messages.at(-1).body, 'Fresh answer');
});

test('new user follow-up resets answered status and bounded reads select sections', async () => {
  const { store } = fixture();
  const a = await store.createThread(alice, create);
  const job = await store.claimAssistantReply(a.id, 'assistant-request-1');
  await store.completeAssistantReply(job.messageId, 'First answer');
  const reply = await store.reply(alice, { threadId: a.id, requestId: 'request-reply-1', body: 'A follow-up question' });
  assert.equal(reply.aiStatus, 'idle');
  await store.createThread(alice, { ...create, requestId: 'request-create-2', sectionId: 'proposals' });
  assert.equal((await store.listThreads('architecture')).length, 1);
  assert.equal((await store.listThreads(undefined, 1)).length, 1);
});

test('assistant manual replies have explicit server-generated authorship and idempotency', async () => {
  const { store } = fixture();
  const thread = await store.createThread(alice, create);
  const input = { threadId: thread.id, requestId: 'manual-response-1', body: 'The stored counter is a producer-side transfer result.' };
  const first = await store.postAssistantReply(alice, input);
  const retry = await store.postAssistantReply(alice, input);
  assert.equal(first.messages.length, 2);
  assert.equal(retry.messages.length, 2);
  assert.equal(retry.messages.at(-1).role, 'assistant');
  assert.equal(retry.messages.at(-1).authorName, 'Codex');
});

test('validation bounds section anchors and text, retaining user text as plain data', () => {
  assert.equal(checkedSection('proposals'), 'proposals');
  assert.throws(() => checkedSection('../outside'), DiscussionError);
  assert.throws(() => checkedText(' '), DiscussionError);
  assert.throws(() => checkedText('x'.repeat(8001)), DiscussionError);
  assert.equal(checkedText('<script>alert(1)</script>'), '<script>alert(1)</script>');
});
