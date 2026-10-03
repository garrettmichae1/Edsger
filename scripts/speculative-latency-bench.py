import json, os, pathlib, subprocess, sys, time, urllib.request
# Standalone investigation only. Run without other inference benchmarks.
if len(sys.argv) != 5:
    raise SystemExit("Usage: speculative-latency-bench.py LLAMA_BIN_DIR MODEL FIXTURE_DIR OUTPUT_DIR")
lib, model, fixtures, output = sys.argv[1:]
root=pathlib.Path(output)
root.mkdir(parents=True, exist_ok=True)
fixtures=pathlib.Path(fixtures)
env=dict(os.environ,LD_LIBRARY_PATH=lib,DYLD_LIBRARY_PATH=lib)
results=[]
for mode in ['none','ngram-simple']:
    args=[lib+'/llama-server','-m',model,'-c','8192','-b','256','-ub','256','-t','4','-tb','4','-ngl','0','-np','1','--host','127.0.0.1','--port','18089','--no-cache-prompt','--cache-ram','0','--ctx-checkpoints','0','--no-warmup','--spec-type',mode]
    if mode!='none': args += ['--spec-ngram-simple-size-n','4','--spec-ngram-simple-size-m','8','--spec-draft-n-max','8']
    with open(root/('spec-'+mode+'.log'),'w') as log:
        proc=subprocess.Popen(args,env=env,stdout=log,stderr=log)
        try:
            deadline=time.monotonic()+90
            while True:
                if proc.poll() is not None: raise RuntimeError('server failed: '+mode)
                try:
                    with urllib.request.urlopen('http://127.0.0.1:18089/health',timeout=1) as response:
                        if response.status==200: break
                except Exception:
                    if time.monotonic()>deadline: raise
                    time.sleep(.2)
            for label,filename in [('code','agent-c.txt'),('text','chat-b.txt')]:
                payload={'prompt':(fixtures/filename).read_text(),'n_predict':256,'temperature':0,'cache_prompt':False,'seed':0,'return_tokens':True}
                if label=='code':payload['grammar']=(fixtures/'agent.gbnf').read_text()
                request=urllib.request.Request('http://127.0.0.1:18089/completion',data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})
                start=time.monotonic()
                with urllib.request.urlopen(request,timeout=180) as response: data=json.load(response)
                result={'mode':mode,'case':label,'wall_s':time.monotonic()-start,'timings':data.get('timings'),'content':data.get('content'),'tokens':data.get('tokens'),'stop_type':data.get('stop_type')}
                results.append(result)
                (root/'spec-results.json').write_text(json.dumps(results,indent=2))
                print(json.dumps({k:v for k,v in result.items() if k not in ['content','tokens']}),flush=True)
        finally:
            proc.terminate()
            try:proc.wait(timeout=10)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
equivalent = True
for label in ['code','text']:
    before,after=[r for r in results if r['case']==label]
    print(label,'identical_text',before['content']==after['content'],'identical_tokens',before['tokens']==after['tokens'],flush=True)

    equivalent &= before["content"] == after["content"] and before["tokens"] == after["tokens"]
if not equivalent:
    raise SystemExit("Speculation failed output equivalence; do not count differing work as a speedup.")
