#include "llama.h"
#include "ggml-backend.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>
#include <stdexcept>
// Investigation harness only; not linked into the iOS app.
static std::string fixtureDir, outputDir;
using Clock = std::chrono::steady_clock;
static double elapsed(Clock::time_point t) { return std::chrono::duration<double>(Clock::now()-t).count(); }
static void check(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
static std::string read(const std::string &name) { std::ifstream f(fixtureDir+"/"+name); check(f.good(),"missing input"); return {std::istreambuf_iterator<char>(f),{}}; }
static std::vector<llama_token> tokenize(const llama_vocab *vocab,const std::string &text) {
    std::vector<llama_token> result(text.size()+32);
    int n=llama_tokenize(vocab,text.data(),(int)text.size(),result.data(),(int)result.size(),true,true);
    check(n>0,"tokenization failed"); result.resize(n); return result;
}
static void decode(llama_context *ctx, std::vector<llama_token> &tokens,size_t start,size_t end) {
    for(size_t i=start;i<end;i+=256) check(llama_decode(ctx,llama_batch_get_one(tokens.data()+i,(int)std::min<size_t>(256,end-i)))==0,"decode failed");
    llama_synchronize(ctx);
}
struct Sampler {
    llama_sampler *candidate=llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler *constrained=nullptr,*grammar=nullptr;
    Sampler(const llama_vocab *vocab,const std::string &source) {
        llama_sampler_chain_add(candidate,llama_sampler_init_greedy());
        if(!source.empty()) {
            constrained=llama_sampler_chain_init(llama_sampler_chain_default_params());
            grammar=llama_sampler_init_grammar(vocab,source.c_str(),"root"); check(grammar,"grammar failed");
            llama_sampler_chain_add(constrained,grammar); llama_sampler_chain_add(constrained,llama_sampler_init_greedy());
        }
    }
    ~Sampler(){llama_sampler_free(candidate);llama_sampler_free(constrained);}
    llama_token next(llama_context *ctx) {
        auto token=llama_sampler_sample(candidate,ctx,-1); if(!grammar)return token;
        llama_token_data one={token,1,0};llama_token_data_array data={&one,1,-1,false};llama_sampler_apply(grammar,&data);
        if(one.logit!=-INFINITY){llama_sampler_accept(constrained,token);return token;}
        return llama_sampler_sample(constrained,ctx,-1);
    }
};
struct Answer {std::vector<llama_token> tokens;std::string text;double seconds;bool ended=false;};
static Answer generate(llama_context *ctx,const llama_vocab *vocab,const std::string &grammar,int limit=256) {
    Sampler sampler(vocab,grammar);Answer answer;auto t=Clock::now();
    for(int i=0;i<limit;i++) {
        auto token=sampler.next(ctx);answer.tokens.push_back(token);
        if(llama_vocab_is_eog(vocab,token)){answer.ended=true;break;}
        char piece[4096];int n=llama_token_to_piece(vocab,token,piece,sizeof(piece),0,false);
        check(n>=0,"piece overflow");answer.text.append(piece,n);
        check(llama_decode(ctx,llama_batch_get_one(&token,1))==0,"generation failed");
    }
    llama_synchronize(ctx);answer.seconds=elapsed(t);return answer;
}
int main(int argc, char **argv) {
    if (argc != 5) {
        std::cerr << "Usage: cache-bench MODEL BACKEND_DIR FIXTURE_DIR OUTPUT_DIR\n";
        return 2;
    }
    fixtureDir = argv[3]; outputDir = argv[4];
    ggml_backend_load_all_from_path(argv[2]);llama_backend_init();
    auto mp=llama_model_default_params();mp.n_gpu_layers=0;
    auto model=llama_model_load_from_file(argv[1],mp);check(model,"model failed");
    auto cp=llama_context_default_params();cp.n_ctx=8192;cp.n_batch=256;cp.n_ubatch=256;cp.n_threads=4;cp.n_threads_batch=4;
    auto ctx=llama_init_from_model(model,cp);check(ctx,"context failed");auto vocab=llama_model_get_vocab(model);
    const int nv=llama_vocab_n_tokens(vocab);
    for(auto label:{std::string("agent-first"),std::string("agent-next"),std::string("chat"),std::string("math")}) {
        std::string from=label=="agent-first"?"agent-a":label=="agent-next"?"agent-b":label+"-a";
        std::string to=label=="agent-first"?"agent-b":label=="agent-next"?"agent-c":label+"-b";
        auto source=tokenize(vocab,read(from+".txt")),target=tokenize(vocab,read(to+".txt"));
        // A single bounded checkpoint before the completion marker, aligned with production prefill batches.
        check(source.size()>264,"fixture too short for an aligned checkpoint");
        size_t boundary=std::min<size_t>(1536,((source.size()-8)/256)*256);
        check(boundary>0 && boundary<target.size() && std::equal(source.begin(),source.begin()+boundary,target.begin()),"checkpoint is not an exact prefix");
        llama_memory_clear(llama_get_memory(ctx),false);decode(ctx,source,0,boundary);
        auto t=Clock::now();size_t bytes=llama_state_seq_get_size(ctx,0);std::vector<uint8_t> state(bytes);
        check(llama_state_seq_get_data(ctx,state.data(),state.size(),0)==bytes,"save failed");double save=elapsed(t);
        decode(ctx,source,boundary,source.size());generate(ctx,vocab,"",8); // Saved state must survive later generation.
        const std::string grammar=label.rfind("agent",0)==0?read("agent.gbnf"):label=="math"?read("math.gbnf"):"";
        llama_memory_clear(llama_get_memory(ctx),false);t=Clock::now();decode(ctx,target,0,target.size());double full=elapsed(t);
        std::vector<float> reference(llama_get_logits_ith(ctx,-1),llama_get_logits_ith(ctx,-1)+nv);
        auto baseline=generate(ctx,vocab,grammar);
        llama_memory_clear(llama_get_memory(ctx),false);t=Clock::now();
        check(llama_state_seq_set_data(ctx,state.data(),state.size(),0)==bytes,"restore failed");double restore=elapsed(t);
        t=Clock::now();decode(ctx,target,boundary,target.size());double suffix=elapsed(t);
        auto logits=llama_get_logits_ith(ctx,-1);double maxDelta=0;
        for(int i=0;i<nv;i++)maxDelta=std::max(maxDelta,std::abs((double)logits[i]-reference[i]));
        auto cached=generate(ctx,vocab,grammar);
        check(baseline.ended&&cached.ended,"answer exceeded limit");check(baseline.tokens==cached.tokens,"cached output differs");
        std::ofstream answerFile(outputDir+"/"+label+"-answer.txt");
        check(answerFile.good(),"cannot open answer output"); answerFile<<cached.text;
        auto other=target;other[0]=(other[0]+1)%nv;check(!std::equal(source.begin(),source.begin()+boundary,other.begin()),"changed prefix was accepted");
        std::cout<<std::fixed<<std::setprecision(6)<<"{\"case\":\""<<label<<"\",\"input\":"<<target.size()<<",\"reused\":"<<boundary<<",\"state_mib\":"<<(double)bytes/1048576<<",\"save_s\":"<<save<<",\"cold_prompt_s\":"<<full<<",\"restore_s\":"<<restore<<",\"suffix_s\":"<<suffix<<",\"baseline_generation_s\":"<<baseline.seconds<<",\"cached_generation_s\":"<<cached.seconds<<",\"output_tokens\":"<<cached.tokens.size()<<",\"max_logit_delta\":"<<maxDelta<<",\"identical\":true}"<<std::endl;
    }
    llama_free(ctx);llama_model_free(model);
}
