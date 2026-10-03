import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import ts from 'typescript';
const source = await readFile(new URL('../src/byok.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
const { handleBYOK, openAIRequest, claudeRequest } = await import('data:text/javascript;base64,' + Buffer.from(js).toString('base64'));
const key = 'test-personal-secret-123456';
const tool = { type: 'function', function: { name: 'read_file', description: 'Read', parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } } };
const body = (model = 'gpt-4.1-mini') => ({ model, messages: [{ role: 'system', content: 'Tutor' }, { role: 'user', content: 'Read main.py' }], tools: [tool] });
const call = { id: 'call_1', type: 'function', function: { name: 'read_file', arguments: '{"path":"main.py"}' } };
const env = (extra = {}) => ({ BYOK_ENABLED: 'true', BYOK_RATE_SALT: 'test-salt-only', BYOK_RATE_LIMIT: { limit: async () => ({ success: true }) }, ...extra });
const json = value => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } });
const textOutput = (text = 'Done') => ({ status: 'completed', output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] }] });
async function send(provider, action, payload, fetcher, overrides = {}, requestOptions = {}) {
  const url = new URL(`https://api.lilc.app/v1/byok/${provider}/${action}`);
  const request = new Request(url, { method: 'POST', headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' }, body: JSON.stringify(payload), ...requestOptions });
  const response = await handleBYOK(request, env(overrides), url, fetcher);
  return { response, value: await response.json() };
}
test('OpenAI tool pairs retain encrypted reasoning, disable storage and parallel calls', () => {
  const b = body();
  const items = [{ type: 'reasoning', id: 'rs_1', encrypted_content: 'opaque' }, { type: 'function_call', call_id: call.id, name: call.function.name, arguments: call.function.arguments }];
  b.messages.push({ role: 'assistant', content: '', tool_calls: [call], edsger_continuation: JSON.stringify({ provider: 'openai', model: b.model, items }) }, { role: 'tool', tool_call_id: call.id, content: 'print(1)' });
  const native = openAIRequest(b);
  assert.equal(native.store, false); assert.equal(native.parallel_tool_calls, false);
  assert.deepEqual(native.include, ['reasoning.encrypted_content']);
  assert.deepEqual(native.input.slice(1, 3), items);
  assert.deepEqual(native.input.at(-1), { type: 'function_call_output', call_id: 'call_1', output: 'print(1)' });
});
test('model switches reconstruct calls instead of replaying opaque state', () => {
  const b = body();
  b.messages.push({ role: 'assistant', content: '', tool_calls: [call], edsger_continuation: JSON.stringify({ provider: 'anthropic', model: 'claude-sonnet-4-5', items: [{ type: 'thinking', signature: 'foreign' }] }) }, { role: 'tool', tool_call_id: call.id, content: 'ok' });
  const native = openAIRequest(b);
  assert.equal(native.input[1].type, 'function_call'); assert.ok(!JSON.stringify(native).includes('foreign'));
});
test('Claude groups multiple tool results in the next user message', () => {
  const b = body('claude-sonnet-4-5'); const second = { ...call, id: 'call_2' };
  b.messages.push({ role: 'assistant', content: 'Reading', tool_calls: [call, second] }, { role: 'tool', tool_call_id: call.id, content: 'a' }, { role: 'tool', tool_call_id: second.id, content: 'b' });
  const native = claudeRequest(b);
  assert.equal(native.messages.length, 3);
  assert.deepEqual(native.messages[2].content.map(x => x.tool_use_id), ['call_1', 'call_2']);
  assert.equal(native.tool_choice.disable_parallel_tool_use, true);
});
test('relay uses fixed OpenAI URL and only the personal upstream credential', async () => {
  const { value, response } = await send('openai', 'completions', body(), async (url, init) => {
    assert.equal(url, 'https://api.openai.com/v1/responses'); assert.equal(init.headers.Authorization, `Bearer ${key}`);
    assert.equal(init.redirect, 'error'); assert.deepEqual(Object.keys(init.headers).sort(), ['Authorization', 'Content-Type']);
    return json(textOutput());
  });
  assert.equal(value.assistantText, 'Done'); assert.equal(response.headers.get('Cache-Control'), 'no-store');
});
test('Claude uses its native version and x-api-key headers', async () => {
  const { value } = await send('anthropic', 'completions', body('claude-sonnet-4-5'), async (url, init) => {
    assert.equal(url, 'https://api.anthropic.com/v1/messages'); assert.equal(init.headers['x-api-key'], key);
    assert.equal(init.headers['anthropic-version'], '2023-06-01'); assert.equal(init.headers.Authorization, undefined);
    return json({ stop_reason: 'tool_use', content: [{ type: 'tool_use', id: call.id, name: 'read_file', input: { path: 'main.py' } }] });
  });
  assert.equal(value.toolCalls[0].argumentsJSON, '{"path":"main.py"}');
});
for (const status of [401, 402, 403, 429, 500]) test(`upstream ${status} never exposes its body or retries a different account`, async () => {
  let count = 0;
  const { response, value } = await send('openai', 'completions', body(), async () => { count++; return new Response(`private ${key}`, { status }); });
  assert.ok(response.status >= 400); assert.ok(!JSON.stringify(value).includes(key)); assert.equal(count, 1);
});
for (const override of [{ BYOK_ENABLED: 'false' }, { BYOK_RATE_LIMIT: undefined }, { BYOK_RATE_SALT: undefined }]) test('missing deployment protection fails closed', async () => {
  const { response, value } = await send('openai', 'models', {}, () => { throw Error('must not fetch'); }, override);
  assert.equal(response.status, 503); assert.equal(value.error, 'byok_not_configured');
});
test('rate identity is an HMAC and rejection prevents upstream requests', async () => {
  const { response } = await send('openai', 'models', {}, () => { throw Error('must not fetch'); }, { BYOK_RATE_LIMIT: { limit: async ({ key: identity }) => { assert.match(identity, /^[a-f0-9]{64}$/); assert.ok(!identity.includes(key)); return { success: false }; } } });
  assert.equal(response.status, 429);
});
for (const kind of ['orphan', 'missing', 'duplicate', 'interleaved']) test(`invalid ${kind} tool history fails before requesting AI`, async () => {
  const b = body();
  if (kind === 'orphan') b.messages.push({ role: 'tool', content: 'x', tool_call_id: 'ghost' });
  else { b.messages.push({ role: 'assistant', content: '', tool_calls: kind === 'duplicate' ? [call, call] : [call] }); if (kind === 'interleaved') b.messages.push({ role: 'user', content: 'next' }); }
  const { response } = await send('openai', 'completions', b, () => { throw Error('must not fetch'); });
  assert.equal(response.status, 400);
});
test('unsupported and injected models cannot change the upstream destination', async () => {
  for (const model of ['https://evil.invalid', 'gpt-4o-realtime-preview', 'tts-1']) {
    const { value } = await send('openai', 'completions', body(model), () => { throw Error('must not fetch'); });
    assert.equal(value.error, 'unsupported_model');
  }
});
test('OpenAI verification forces a harmless tool and feeds its result back', async () => {
  let count = 0;
  const { value } = await send('openai', 'verify', { model: body().model }, async (_, init) => {
    const p = JSON.parse(init.body); count++;
    if (count === 1) { assert.deepEqual(p.tool_choice, { type: 'function', name: 'edsger_connection_check' }); return json({ status: 'completed', output: [{ type: 'function_call', call_id: 'probe', name: 'edsger_connection_check', arguments: '{"value":"OK"}' }] }); }
    assert.deepEqual(p.input.at(-1), { type: 'function_call_output', call_id: 'probe', output: 'OK' }); return json(textOutput('OK'));
  });
  assert.deepEqual(value, { ok: true }); assert.equal(count, 2);
});
test('Claude verification uses tool_use / tool_result pairing', async () => {
  let count = 0;
  const { value } = await send('anthropic', 'verify', { model: 'claude-sonnet-4-5' }, async (_, init) => {
    const p = JSON.parse(init.body); count++;
    if (count === 1) return json({ stop_reason: 'tool_use', content: [{ type: 'tool_use', id: 'probe', name: 'edsger_connection_check', input: { value: 'OK' } }] });
    assert.deepEqual(p.messages.at(-1).content, [{ type: 'tool_result', tool_use_id: 'probe', content: 'OK' }]);
    return json({ stop_reason: 'end_turn', content: [{ type: 'text', text: 'OK' }] });
  });
  assert.deepEqual(value, { ok: true }); assert.equal(count, 2);
});
test('verification rejects models that skip the tool', async () => {
  const { value } = await send('openai', 'verify', { model: body().model }, async () => json(textOutput()));
  assert.equal(value.error, 'tool_test_failed');
});
test('Claude model catalog paginates, filters and deduplicates', async () => {
  let count = 0;
  const { value } = await send('anthropic', 'models', {}, async url => {
    count++;
    if (count === 1) return json({ data: [{ id: 'claude-sonnet-4-5', display_name: 'Sonnet' }], has_more: true, last_id: 'claude-sonnet-4-5' });
    assert.ok(url.endsWith('&after_id=claude-sonnet-4-5'));
    return json({ data: [{ id: 'claude-sonnet-4-5', display_name: 'Sonnet' }, { id: 'embedding-v1' }], has_more: false });
  });
  assert.deepEqual(value.models, [{ id: 'claude-sonnet-4-5', name: 'Sonnet' }]);
});
for (const output of [{ status: 'incomplete', output: [] }, { status: 'completed', output: [] }, { status: 'completed', output: [{ type: 'function_call', call_id: 'x', name: 'unknown', arguments: '{}' }] }]) test('incomplete or unregistered output produces no executable calls', async () => {
  const { response, value } = await send('openai', 'completions', body(), async () => json(output));
  assert.equal(response.status, 502); assert.equal(value.toolCalls, undefined);
});
test('bounded bodies reject oversize before upstream fetch', async () => {
  const { response } = await send('openai', 'models', { input: 'x'.repeat(385 * 1024) }, () => { throw Error('must not fetch'); });
  assert.equal(response.status, 413);
});
test('cancellation propagates to the upstream signal without a retry', async () => {
  const controller = new AbortController(); let count = 0;
  const { value } = await send('openai', 'completions', body(), async (_, init) => {
    count++; controller.abort(); assert.equal(init.signal.aborted, true); throw new DOMException('private cancellation', 'AbortError');
  }, {}, { signal: controller.signal });
  assert.equal(count, 1); assert.deepEqual(value, { error: 'provider_unavailable' });
});
test('stale native calls cannot override the normalized transcript', async () => {
  const b = body(); b.messages.push({ role: 'assistant', content: '', tool_calls: [call], edsger_continuation: JSON.stringify({ provider: 'openai', model: b.model, items: [{ type: 'function_call', call_id: 'wrong', name: 'write_file', arguments: '{}' }] }) }, { role: 'tool', tool_call_id: call.id, content: 'ok' });
  const { value } = await send('openai', 'completions', b, () => { throw Error('must not fetch'); });
  assert.equal(value.error, 'invalid_continuation');
});

test('native arguments must match the canonical tool transcript', async () => {
  const b = body(); b.messages.push({ role: 'assistant', content: '', tool_calls: [call], edsger_continuation: JSON.stringify({ provider: 'openai', model: b.model, items: [{ type: 'function_call', call_id: call.id, name: call.function.name, arguments: '{"path":"different.py"}' }] }) }, { role: 'tool', tool_call_id: call.id, content: 'ok' });
  const { value } = await send('openai', 'completions', b, () => { throw Error('must not fetch'); });
  assert.equal(value.error, 'invalid_continuation');
});

test('simultaneous users never share credentials or rate identities', async () => {
  const keys = ['personal-user-one-key-123456', 'personal-user-two-key-123456'];
  const identities = new Set(), observed = new Set();
  const limiter = { limit: async ({ key: identity }) => { identities.add(identity); return { success: true }; } };
  await Promise.all(keys.map(secret => send('openai', 'completions', body(), async (_, init) => {
    observed.add(init.headers.Authorization); return json(textOutput());
  }, { BYOK_RATE_LIMIT: limiter }, { headers: { Authorization: `Bearer ${secret}`, 'Content-Type': 'application/json' } })));
  assert.deepEqual([...observed].sort(), keys.map(secret => `Bearer ${secret}`).sort());
  assert.equal(identities.size, 2);
});
test('current Claude verification accepts always-on thinking without forced tool choice', async () => {
  let count = 0;
  const { value } = await send('anthropic', 'verify', { model: 'claude-opus-5-5' }, async (_, init) => {
    const p = JSON.parse(init.body); count++;
    assert.equal(p.tool_choice.type, 'auto');
    if (count === 1) return json({ stop_reason: 'tool_use', content: [{ type: 'thinking', thinking: '', signature: 'prefix-bound-signature' }, { type: 'tool_use', id: 'probe', name: 'edsger_connection_check', input: { value: 'OK' } }] });
    assert.deepEqual(p.messages[1].content[0], { type: 'thinking', thinking: '', signature: 'prefix-bound-signature' });
    assert.equal(p.messages[0].content[0].text, 'Call edsger_connection_check with value OK, then acknowledge its result in one word.');
    return json({ stop_reason: 'end_turn', content: [{ type: 'thinking', thinking: '', signature: 'next-signature' }, { type: 'text', text: 'OK' }] });
  });
  assert.deepEqual(value, { ok: true });
});
test('Claude catalog includes current named coding/reasoning families and legacy output caps are respected', async () => {
  const { value } = await send('anthropic', 'models', {}, async () => json({ data: [{ id: 'claude-fable-5-1', display_name: 'Fable' }, { id: 'claude-mythos-5-1', display_name: 'Mythos' }], has_more: false }));
  assert.equal(value.models.length, 2);
  assert.equal(claudeRequest(body('claude-3-haiku-20240307')).max_tokens, 4096);
});
for (const [provider, status, error, expected] of [
  ['openai', 429, { code: 'credit_balance_exhausted', type: 'insufficient_quota' }, 'insufficient_credit'],
  ['openai', 429, { code: 'project_spend_limit_exceeded', type: 'insufficient_quota' }, 'provider_spend_limit'],
  ['anthropic', 400, { type: 'invalid_request_error', message: 'Your credit balance is too low to access the API.' }, 'insufficient_credit'],
  ['anthropic', 400, { type: 'invalid_request_error', message: 'Your workspace spend limit was reached.' }, 'provider_spend_limit'],
]) test(`${provider} billing errors are distinguished from temporary traffic limits`, async () => {
  let count = 0;
  const { value } = await send(provider, 'completions', body(provider === 'openai' ? 'gpt-4.1-mini' : 'claude-opus-5-5'), async () => { count++; return new Response(JSON.stringify({ error: { ...error, private: key } }), { status }); });
  assert.deepEqual(value, { error: expected }); assert.equal(count, 1);
});
test('saved native tool arguments tolerate JSON object-key reordering', () => {
  const b = body('claude-opus-5-5');
  const c = { id: 'write', type: 'function', function: { name: 'write_file', arguments: '{"path":"main.py","contents":"print(1)"}' } };
  b.messages.push({ role: 'assistant', content: '', tool_calls: [c], edsger_continuation: JSON.stringify({ provider: 'anthropic', model: b.model, items: [{ type: 'tool_use', id: c.id, name: c.function.name, input: { contents: 'print(1)', path: 'main.py' } }] }) }, { role: 'tool', tool_call_id: c.id, content: 'Created' });
  assert.equal(claudeRequest(b).messages[1].content[0].input.path, 'main.py');
});
