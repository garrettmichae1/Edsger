import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { importPKCS8, SignJWT } from 'jose';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dir = await mkdtemp(join(tmpdir(), 'edsger-mobile-'));
async function compile(path) {
  const file = join(dir, path.split('/').pop() + '.mjs');
  await build({ entryPoints: [path], outfile: file, bundle: true, platform: 'node', format: 'esm',
    banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" } });
  return import(file);
}
const meter = await compile('src/paid-meter.ts');
const model = await compile('src/paid-model.ts');
const { MobileAgentLedger } = await compile('src/paid-ledger.ts');
const { default: worker } = await compile('src/index.ts');
const { paidIdentity } = await compile('src/paid-auth.ts');
test.after(() => rm(dir, { recursive: true, force: true }));
const id = (plus = false) => ({ originalID: '100000000001', transactionID: '200000000001',
  productID: plus ? 'lilc.pro.plus.monthly' : 'lilc.pro.monthly', purchaseDate: Date.now() - 1000, expiresDate: Date.now() + 30 * 86400000 });
const input = { messages: [{ role: 'user', content: 'Say hello' }], tools: [] };
const usage = { prompt_tokens: 10000, prompt_cache_hit_tokens: 8000, prompt_cache_miss_tokens: 2000, completion_tokens: 2000, total_tokens: 12000 };
const reply = { usage, choices: [{ finish_reason: 'stop', message: { content: 'Hello' } }] };
const uuid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

// Transactional fixture with rollback and serialized transactions; use two
// separate actor instances to ensure correctness comes from storage, not RAM.
class Storage {
  data = new Map(); tail = Promise.resolve();
  async transaction(fn) {
    const previous = this.tail; let release;
    this.tail = new Promise(resolve => { release = resolve; });
    await previous;
    const copy = structuredClone(this.data);
    const tx = { get: async k => copy.get(k), put: async (k,v) => copy.set(k,structuredClone(v)), delete: async k => copy.delete(k) };
    try { const result = await fn(tx); this.data = copy; return result; }
    finally { release(); }
  }
}
function ledger(storage = new Storage()) { return { storage, actor: new MobileAgentLedger({ storage }, { PAID_AGENT_ENABLED: 'true', DEEPSEEK_API_KEY: 'server-only-fixture-key' }) }; }
function request(identity, n, body = input, path = 'completions') {
  return new Request(`https://ledger/${path}`, { method: 'POST', body: JSON.stringify({ identity, requestID: uuid(n), body }) });
}
async function withProvider(response, fn) {
  const saved = globalThis.fetch; let calls = 0;
  globalThis.fetch = async (url, options) => {
    calls++;
    assert.equal(url, 'https://api.deepseek.com/chat/completions');
    assert.equal(options.redirect, 'error');
    assert.equal(options.headers.Authorization, 'Bearer server-only-fixture-key');
    const body = JSON.parse(options.body);
    assert.equal(body.model, 'deepseek-flash');
    assert.equal(body.thinking.type, 'disabled');
    assert.equal(body.max_tokens, 8192);
    return typeof response === 'function' ? response() : new Response(JSON.stringify(response), { status: 200 });
  };
  try { return await fn(() => calls); } finally { globalThis.fetch = saved; }
}

test('exact $5/$15 allowances and nano-dollar billing, including cache and reasoning', () => {
  assert.equal(meter.PRODUCT_LIMITS['lilc.pro.monthly'], 5000000000n);
  assert.equal(meter.PRODUCT_LIMITS['lilc.pro.plus.monthly'], 15000000000n);
  assert.equal(meter.usageCost(usage), 3048000n);
  assert.equal(meter.usageCost({ ...usage, completion_tokens_details: { reasoning_tokens: 1000 } }), 3048000n);
  let sum = 0n; for (let i=0;i<100000;i++) sum += meter.usageCost(usage);
  assert.equal(sum, 304800000000n);
});
test('missing, inconsistent, negative, fractional or unbounded usage is never billed as zero', () => {
  for (const bad of [undefined, {}, { ...usage,prompt_tokens:9999 }, { ...usage,completion_tokens:-1 }, { ...usage,prompt_cache_hit_tokens:0.5 }, { ...usage,total_tokens:NaN }, { ...usage,completion_tokens:9000,total_tokens:19000 }]) {
    assert.throws(() => meter.usageCost(bad));
  }
});
test('restore and upgrades retain spending; renewal resets; old receipts cannot rewind', () => {
  const identity = id(); const now = Date.now();
  const p = { ...meter.periodFor(undefined,identity,now),spent:'1200000000',held:'5000' };
  assert.deepEqual(meter.periodFor(p,identity,now),p);
  const upgrade = { ...identity,productID:'lilc.pro.plus.monthly',purchaseDate:now };
  const next = meter.periodFor(p,upgrade,now);
  assert.equal(next.spent,'1200000000'); assert.equal(next.held,'5000'); assert.equal(next.limit,'15000000000');
  assert.throws(() => meter.periodFor(next,identity,now));
  const renewal = { ...identity,purchaseDate:p.end,expiresDate:p.end+30*86400000 };
  assert.equal(meter.periodFor(p,renewal,p.end+1).spent,'0');
});
test('client cannot select a more expensive model or enable thinking / unbounded output', () => {
  const wire = model.modelRequest({ ...input,model:'expensive',thinking:{type:'enabled'},max_tokens:999999 });
  assert.equal(wire.model,'deepseek-flash'); assert.equal(wire.thinking.type,'disabled'); assert.equal(wire.max_tokens,8192);
});
test('truncated output, duplicate tools and unknown tools are rejected before execution', () => {
  const wire = model.modelRequest(input);
  assert.throws(() => model.modelCompletion({ choices:[{ finish_reason:'length',message:{content:'half a file'} }] },wire));
  assert.throws(() => model.modelRequest({ ...input,tools:[{type:'function',function:{name:'shell',description:'bad',parameters:{}}}] }));
  assert.throws(() => model.modelCompletion({ choices:[{finish_reason:'tool_calls',message:{tool_calls:[{id:'x',function:{name:'write_file',arguments:'{}'}}]}}] },wire));
});
test('disabled worker does not read prompt, receipt, or ledger and legacy paid routes are retired', async () => {
  const req = new Request('https://agent/v1/mobile-agent/completions',{method:'POST',body:'secret'});
  const env = new Proxy({PAID_AGENT_ENABLED:'false'},{get(target,key){if(key==='PAID_AGENT_ENABLED') return target[key];throw Error('must not access secrets');}});
  const response = await worker.fetch(req,env); assert.equal(response.status,503); assert.equal(req.bodyUsed,false);
  assert.equal(response.headers.get('Cache-Control'),'no-store');
  assert.equal((await worker.fetch(new Request('https://agent/v1/chat/completions'),{})).status,410);
});
test('client identity/debug flags cannot authenticate a paid user', async () => {
  await assert.rejects(paidIdentity(new Request('https://agent',{headers:{'X-LilC-Debug':'yes','X-LilC-Device':'arbitrary-device'}}),{}));
  const response = await worker.fetch(new Request('https://agent/v1/mobile-agent/allowance'),{PAID_AGENT_ENABLED:'true',DEEPSEEK_API_KEY:'fixture',MOBILE_AGENT_LEDGER:{},APPLE_BUNDLE_ID:'app.lilc'});
  assert.equal(response.status,503);
});
test('attacker-signed x5c transaction cannot impersonate an Apple subscription', async () => {
  for (const label of ['attacker','trusted']) execFileSync('openssl',['req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-days','1','-subj',`/CN=${label}`,'-keyout',join(dir,label+'.key'),'-out',join(dir,label+'.pem')],{stdio:'ignore'});
  const pem=await readFile(join(dir,'attacker.pem'),'utf8');
  const cert=pem.replace(/-----[^-]+-----|\s/g,'');
  const key=await importPKCS8(await readFile(join(dir,'attacker.key'),'utf8'),'ES256');
  const jws=await new SignJWT({bundleId:'app.lilc',productId:'lilc.pro.monthly',environment:'Production',originalTransactionId:'100000000001',transactionId:'200000000001',purchaseDate:Date.now()-1000,expiresDate:Date.now()+86400000}).setProtectedHeader({alg:'ES256',x5c:[cert,cert,cert]}).sign(key);
  const root=await readFile(join(dir,'trusted.pem'));
  const env={APPLE_ROOT_CERTIFICATES:JSON.stringify([root.toString('base64')]),APPLE_ISSUER_ID:'fixture',APPLE_KEY_ID:'fixture',APPLE_PRIVATE_KEY:'unused',APPLE_APP_ID:'123',APPLE_BUNDLE_ID:'app.lilc',APPLE_ENVIRONMENT:'Production'};
  const saved=globalThis.fetch;let calls=0;globalThis.fetch=async()=>{calls++;throw Error('forged receipt must not contact Apple or provider');};
  try { await assert.rejects(paidIdentity(new Request('https://agent',{headers:{'X-Apple-Transaction-JWS':jws}}),env));assert.equal(calls,0); }
  finally {globalThis.fetch=saved;}
});
test('settlement bills once and duplicate IDs never invoke the provider again', async () => {
  const {actor,storage} = ledger(); const identity=id();
  await withProvider(reply,async count => {
    const response = await actor.fetch(request(identity,1)); assert.equal(response.status,200);
    const body = await response.json(); assert.equal(body.allowance.remainingNanoUSD,String(5000000000n-3048000n));
    assert.equal(storage.data.get('current').held,'0');
    assert.equal((await actor.fetch(request(identity,1))).status,409); assert.equal(count(),1);
  });
});
test('two actor instances sharing storage cannot exceed remaining funds concurrently', async () => {
  const {actor,storage} = ledger(); const other = ledger(storage).actor; const identity=id();
  const p = meter.periodFor(undefined,identity,Date.now());p.spent=String(5000000000n-meter.RESERVATION);
  storage.data.set('current',p); storage.data.set(`period:${p.start}`,p);
  let release; const wait = new Promise(resolve=>{release=resolve;});
  await withProvider(async()=>{await wait;return new Response(JSON.stringify(reply));},async count => {
    const first = actor.fetch(request(identity,1));
    while(!count()) await new Promise(resolve=>setImmediate(resolve));
    const second = await other.fetch(request(identity,2)); assert.equal(second.status,409);
    release(); assert.equal((await first).status,200); assert.equal(count(),1);
    assert(BigInt(storage.data.get('current').spent)<=5000000000n);
  });
});
test('insufficient worst-case capacity rejects without a paid provider request', async () => {
  const {actor,storage}=ledger();const identity=id();
  const p=meter.periodFor(undefined,identity,Date.now());p.spent=String(5000000000n-meter.RESERVATION+1n);
  storage.data.set('current',p);
  await withProvider(reply,async count=>{
    const response=await actor.fetch(request(identity,1));assert.equal(response.status,429);assert.equal((await response.json()).error,'allowance_exhausted');assert.equal(count(),0);
  });
});
test('missing usage retains a reservation; known non-billable rejections release it', async () => {
  for(const [response,expected] of [[{choices:reply.choices},String(meter.RESERVATION)],[()=>new Response('{}',{status:429}),'0']]) {
    const {actor,storage}=ledger();
    await withProvider(response,async()=>{ const result=await actor.fetch(request(id(),1));assert(result.status>=400);assert.equal(storage.data.get('current').held,expected);assert.equal(storage.data.get('current').spent,'0'); });
  }
});
test('invalid generated tools still settle reported billable usage', async () => {
  const {actor,storage}=ledger();
  await withProvider({usage,choices:[{finish_reason:'tool_calls',message:{tool_calls:[{id:'x',function:{name:'shell',arguments:'{}'}}]}}]},async()=>{
    const result=await actor.fetch(request(id(),1));assert.equal(result.status,503);assert.equal(storage.data.get('current').spent,'3048000');assert.equal(storage.data.get('current').held,'0');
  });
});
