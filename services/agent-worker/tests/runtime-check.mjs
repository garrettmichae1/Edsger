// Execute the deployment bundle in the real local Workers runtime. Node unit
// fixtures alone would miss SDK global-scope randomness/crypto incompatibility.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
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
} finally {await rm(dir,{recursive:true,force:true});}
