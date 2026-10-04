// Execute the deployment bundle in the real local Workers runtime. Node unit
// fixtures alone would miss SDK global-scope randomness/crypto incompatibility.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { importPKCS8, SignJWT } from 'jose';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
const dir=await mkdtemp(join(tmpdir(),'edsger-worker-runtime-'));
try {
  execFileSync(process.execPath,['node_modules/wrangler/bin/wrangler.js','deploy','--dry-run','--outdir',dir],{stdio:'pipe',env:{...process.env,WRANGLER_SEND_METRICS:'false'}});
  execFileSync('openssl',['req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-days','1','-subj','/CN=untrusted-runtime-fixture','-keyout',join(dir,'key.pem'),'-out',join(dir,'cert.pem')],{stdio:'ignore'});
  const pem=await readFile(join(dir,'cert.pem'),'utf8'),cert=pem.replace(/-----[^-]+-----|\s/g,'');
  const key=await importPKCS8(await readFile(join(dir,'key.pem'),'utf8'),'ES256');
  const jws=await new SignJWT({bundleId:'app.lilc',productId:'lilc.pro.monthly',environment:'Production',originalTransactionId:'100000000001',transactionId:'200000000001',expiresDate:Date.now()+86400000}).setProtectedHeader({alg:'ES256',x5c:[cert,cert,cert]}).sign(key);
  for(const enabled of [false,true]) {
    const mf=new Miniflare(convertV4MiniflareOptions({rootPath:dir,modulesRoot:dir,modules:true,scriptPath:join(dir,'index.js'),compatibilityDate:'2026-08-01',compatibilityFlags:['nodejs_compat'],
      durableObjects:{MOBILE_AGENT_LEDGER:{className:'MobileAgentLedger',useSQLite:true}},bindings:{PAID_AGENT_ENABLED:String(enabled),DEEPSEEK_API_KEY:'unused-fixture',APPLE_BUNDLE_ID:'app.lilc',APPLE_ENVIRONMENT:'Production',APPLE_APP_ID:'123',APPLE_ISSUER_ID:'fixture',APPLE_KEY_ID:'fixture',APPLE_PRIVATE_KEY:'unused-fixture',APPLE_ROOT_CERTIFICATES:JSON.stringify([Buffer.from(pem).toString('base64')])}}));
    try {
      const health=await mf.dispatchFetch('https://worker/health');assert.equal(health.status,200);
      const response=await mf.dispatchFetch('https://worker/v1/mobile-agent/allowance',{headers:{'X-Apple-Transaction-JWS':jws}});
      assert([403,503].includes(response.status));
      assert.equal(response.headers.get('Cache-Control'),'no-store');
      console.log(`PASS: actual Workers runtime ${enabled?'rejects forged Apple receipt using native crypto':'starts with funded service disabled'}`);
    } finally {await mf.dispose();}
  }
  // A real SQLite-backed Durable Object must actually call and settle a mocked
  // provider. This catches Workers fetch redirect semantics that Node accepts.
  const identity={originalID:'100000000001',transactionID:'200000000001',productID:'lilc.pro.monthly',purchaseDate:Date.now()-1000,expiresDate:Date.now()+30*86400000};
  const entry=join(dir,'ledger-harness.ts');
  await writeFile(entry, `import { MobileAgentLedger } from ${JSON.stringify(resolve('src/paid-ledger.ts'))};
export { MobileAgentLedger };
export default {async fetch(request,env){const identity=${JSON.stringify(identity)};
return env.MOBILE_AGENT_LEDGER.get(env.MOBILE_AGENT_LEDGER.idFromName(identity.originalID)).fetch(new Request('https://ledger'+new URL(request.url).pathname,{method:'POST',body:JSON.stringify({identity,requestID:request.headers.get('request-id'),body:{messages:[{role:'user',content:'Hi'}],tools:[]}})}));}};`);
  const output=join(dir,'ledger');
  execFileSync(process.execPath,['node_modules/wrangler/bin/wrangler.js','deploy',entry,'--config','wrangler.toml','--dry-run','--outdir',output],{stdio:'pipe',env:{...process.env,WRANGLER_SEND_METRICS:'false'}});
  let providerCalls=0;
  const ledger=new Miniflare(convertV4MiniflareOptions({rootPath:output,modulesRoot:output,modules:true,scriptPath:join(output,'ledger-harness.js'),compatibilityDate:'2026-08-01',compatibilityFlags:['nodejs_compat'],
    durableObjects:{MOBILE_AGENT_LEDGER:{className:'MobileAgentLedger',useSQLite:true}},bindings:{PAID_AGENT_ENABLED:'true',DEEPSEEK_API_KEY:'unused-fixture'},outboundService:async request=>{
      assert.equal(request.url,'https://api.deepseek.com/chat/completions');
      providerCalls++; await new Promise(resolve=>setTimeout(resolve,50));
      return new Response(JSON.stringify({usage:{prompt_tokens:1,prompt_cache_hit_tokens:0,prompt_cache_miss_tokens:1,completion_tokens:1,total_tokens:2},choices:[{finish_reason:'stop',message:{content:'Hi'}}]}));
    }}));
  try {
    const uuid=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
    const initial=await ledger.dispatchFetch('https://worker/allowance');assert.equal((await initial.json()).allowance.remainingNanoUSD,'5000000000');
    const results=await Promise.all([1,2].map(n=>ledger.dispatchFetch('https://worker/completions',{headers:{'request-id':uuid(n)}})));
    assert.deepEqual(results.map(r=>r.status).sort(),[200,409]);assert.equal(providerCalls,1);
    const after=await ledger.dispatchFetch('https://worker/allowance');assert.equal((await after.json()).allowance.remainingNanoUSD,'4999998500');
    const winner=results.findIndex(r=>r.status===200)+1;
    assert.equal((await ledger.dispatchFetch('https://worker/completions',{headers:{'request-id':uuid(winner)}})).status,409);assert.equal(providerCalls,1);
    console.log('PASS: actual Workers SQLite ledger settles exact cost and blocks concurrent/duplicate requests');
  } finally {await ledger.dispose();}
} finally {await rm(dir,{recursive:true,force:true});}
