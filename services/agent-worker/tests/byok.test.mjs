import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const dir = await mkdtemp(join(tmpdir(), 'edsger-retired-byok-'));
const file = join(dir, 'worker.mjs');
await build({ entryPoints: ['src/index.ts'], outfile: file, bundle: true, platform: 'node', format: 'esm', banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" } });
const { default: worker } = await import(file);
for (const provider of ['openai', 'anthropic']) for (const action of ['models', 'verify', 'completions']) {
  test(`retired ${provider}/${action} never reads personal credentials or uses worker bindings`, async () => {
    const request = new Request(`https://api.lilc.app/v1/byok/${provider}/${action}`, { method: 'POST', body: 'invalid-json', headers: { Authorization: 'Bearer personal-test-key' } });
    const env = new Proxy({}, { get() { throw Error('Retired BYOK must not access bindings'); } });
    const response = await worker.fetch(request, env);
    assert.equal(response.status, 410);
    assert.equal(request.bodyUsed, false);
    assert.deepEqual(await response.json(), { error: 'byok_direct_only' });
  });
}
test.after(async () => { await rm(dir, { recursive: true, force: true }); });
