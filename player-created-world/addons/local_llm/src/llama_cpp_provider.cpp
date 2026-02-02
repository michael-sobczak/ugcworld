#include "llama_cpp_provider.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

// llama.cpp headers
#include "llama.h"

#include <algorithm>
#include <cstring>

namespace godot {

// Helper function to add a token to a batch (replaces removed llama_batch_add)
static void batch_add(
    struct llama_batch & batch,
    llama_token id,
    llama_pos pos,
    const std::vector<llama_seq_id> & seq_ids,
    bool logits
) {
    batch.token   [batch.n_tokens] = id;
    batch.pos     [batch.n_tokens] = pos;
    batch.n_seq_id[batch.n_tokens] = seq_ids.size();
    for (size_t i = 0; i < seq_ids.size(); ++i) {
        batch.seq_id[batch.n_tokens][i] = seq_ids[i];
    }
    batch.logits[batch.n_tokens] = logits;
    batch.n_tokens++;
}

void LlamaCppProvider::_bind_methods() {
    // Methods
    ClassDB::bind_method(D_METHOD("is_loaded"), &LlamaCppProvider::is_loaded);
    ClassDB::bind_method(D_METHOD("get_loaded_model_id"), &LlamaCppProvider::get_loaded_model_id);
    ClassDB::bind_method(
        D_METHOD("load_model", "model_path", "model_id", "context_length", "n_threads", "n_gpu_layers"),
        &LlamaCppProvider::load_model
    );
    ClassDB::bind_method(D_METHOD("unload_model"), &LlamaCppProvider::unload_model);
    ClassDB::bind_method(D_METHOD("generate", "request"), &LlamaCppProvider::generate);
    ClassDB::bind_method(D_METHOD("cancel", "handle_id"), &LlamaCppProvider::cancel);
    ClassDB::bind_method(D_METHOD("get_status"), &LlamaCppProvider::get_status);
    ClassDB::bind_method(D_METHOD("get_backend_type"), &LlamaCppProvider::get_backend_type);
    ClassDB::bind_method(D_METHOD("estimate_memory_usage", "model_path"), &LlamaCppProvider::estimate_memory_usage);
    ClassDB::bind_method(D_METHOD("get_available_memory"), &LlamaCppProvider::get_available_memory);
    ClassDB::bind_method(D_METHOD("get_recommended_threads"), &LlamaCppProvider::get_recommended_threads);
    ClassDB::bind_method(D_METHOD("is_gpu_available"), &LlamaCppProvider::is_gpu_available);
    ClassDB::bind_method(D_METHOD("set_n_threads", "threads"), &LlamaCppProvider::set_n_threads);
    ClassDB::bind_method(D_METHOD("get_n_threads"), &LlamaCppProvider::get_n_threads);
    ClassDB::bind_method(D_METHOD("set_n_gpu_layers", "layers"), &LlamaCppProvider::set_n_gpu_layers);
    ClassDB::bind_method(D_METHOD("get_n_gpu_layers"), &LlamaCppProvider::get_n_gpu_layers);

    // Enums
    BIND_ENUM_CONSTANT(BACKEND_CPU);
    BIND_ENUM_CONSTANT(BACKEND_CUDA);
    BIND_ENUM_CONSTANT(BACKEND_METAL);
    BIND_ENUM_CONSTANT(BACKEND_VULKAN);
    BIND_ENUM_CONSTANT(BACKEND_UNKNOWN);

    // Properties
    ADD_PROPERTY(PropertyInfo(Variant::INT, "n_threads"), "set_n_threads", "get_n_threads");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "n_gpu_layers"), "set_n_gpu_layers", "get_n_gpu_layers");
}

LlamaCppProvider::LlamaCppProvider() {
    // Initialize llama backend
    llama_backend_init();
    
    // Detect recommended thread count
    m_n_threads = get_recommended_threads();
    
    // Detect backend type
#if defined(GGML_USE_CUDA)
    m_backend_type = BACKEND_CUDA;
#elif defined(GGML_USE_METAL)
    m_backend_type = BACKEND_METAL;
#elif defined(GGML_USE_VULKAN)
    m_backend_type = BACKEND_VULKAN;
#else
    m_backend_type = BACKEND_CPU;
#endif
    
    log_info("LlamaCppProvider initialized");
}

LlamaCppProvider::~LlamaCppProvider() {
    // Ensure worker thread is stopped
    if (m_worker_running.load(std::memory_order_acquire)) {
        {
            std::lock_guard<std::mutex> lock(m_handle_mutex);
            if (m_current_handle.is_valid()) {
                m_current_handle->request_cancel();
            }
        }
        if (m_worker_thread && m_worker_thread->joinable()) {
            m_worker_thread->join();
        }
    }
    
    unload_model();
    llama_backend_free();
    
    log_info("LlamaCppProvider destroyed");
}

void LlamaCppProvider::log_info(const String& p_message) const {
    UtilityFunctions::print("[LocalLLM] ", p_message);
}

void LlamaCppProvider::log_error(const String& p_message) const {
    UtilityFunctions::printerr("[LocalLLM] ERROR: ", p_message);
}

void LlamaCppProvider::log_warning(const String& p_message) const {
    UtilityFunctions::print("[LocalLLM] WARNING: ", p_message);
}

bool LlamaCppProvider::is_loaded() const {
    return m_model != nullptr && m_ctx != nullptr;
}

String LlamaCppProvider::get_loaded_model_id() const {
    return m_loaded_model_id;
}

bool LlamaCppProvider::load_model(
    const String& model_path,
    const String& model_id,
    int context_length,
    int n_threads,
    int n_gpu_layers
) {
    std::lock_guard<std::mutex> lock(m_model_mutex);
    
    // Unload existing model first
    if (m_model != nullptr) {
        unload_model();
    }
    
    log_info("Loading model: " + model_id + " from " + model_path);
    
    // Check if file exists
    if (!FileAccess::file_exists(model_path)) {
        log_error("Model file not found: " + model_path);
        return false;
    }
    
    // Setup model params
    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = n_gpu_layers;
    
    // Load model
    CharString path_utf8 = model_path.utf8();
    m_model = llama_model_load_from_file(path_utf8.get_data(), model_params);
    
    if (m_model == nullptr) {
        log_error("Failed to load model from: " + model_path);
        return false;
    }
    
    // Setup context params
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = context_length;
    ctx_params.n_threads = n_threads;
    ctx_params.n_threads_batch = n_threads;
    
    // Create context
    m_ctx = llama_init_from_model(m_model, ctx_params);
    
    if (m_ctx == nullptr) {
        log_error("Failed to create context for model");
        llama_model_free(m_model);
        m_model = nullptr;
        return false;
    }
    
    m_loaded_model_id = model_id;
    m_loaded_model_path = model_path;
    m_context_length = context_length;
    m_n_threads = n_threads;
    m_n_gpu_layers = n_gpu_layers;
    
    log_info("Model loaded successfully: " + model_id + 
             " (ctx=" + String::num_int64(context_length) + 
             ", threads=" + String::num_int64(n_threads) + 
             ", gpu_layers=" + String::num_int64(n_gpu_layers) + ")");
    
    return true;
}

void LlamaCppProvider::unload_model() {
    // Wait for any ongoing generation
    if (m_worker_running.load(std::memory_order_acquire)) {
        {
            std::lock_guard<std::mutex> lock(m_handle_mutex);
            if (m_current_handle.is_valid()) {
                m_current_handle->request_cancel();
            }
        }
        if (m_worker_thread && m_worker_thread->joinable()) {
            m_worker_thread->join();
        }
    }
    
    if (m_ctx != nullptr) {
        llama_free(m_ctx);
        m_ctx = nullptr;
    }
    
    if (m_model != nullptr) {
        llama_model_free(m_model);
        m_model = nullptr;
    }
    
    m_loaded_model_id = "";
    m_loaded_model_path = "";
    m_context_length = 0;
    
    log_info("Model unloaded");
}

std::vector<int32_t> LlamaCppProvider::tokenize(const String& p_text, bool p_add_bos) const {
    if (m_model == nullptr) {
        return {};
    }
    
    const llama_vocab* vocab = llama_model_get_vocab(m_model);
    
    CharString text_utf8 = p_text.utf8();
    const char* text_cstr = text_utf8.get_data();
    int text_len = text_utf8.length();
    
    // First, get the required size
    int n_tokens = llama_tokenize(
        vocab, text_cstr, text_len,
        nullptr, 0,
        p_add_bos, // add_special (BOS)
        false      // parse_special
    );
    
    // Negative value means we need that many tokens
    if (n_tokens < 0) {
        n_tokens = -n_tokens;
    }
    
    std::vector<int32_t> tokens(n_tokens);
    int actual = llama_tokenize(
        vocab, text_cstr, text_len,
        tokens.data(), tokens.size(),
        p_add_bos,
        false
    );
    
    if (actual < 0) {
        log_error("Tokenization failed");
        return {};
    }
    
    tokens.resize(actual);
    return tokens;
}

String LlamaCppProvider::token_to_string(int32_t p_token) const {
    if (m_model == nullptr) {
        return "";
    }
    
    const llama_vocab* vocab = llama_model_get_vocab(m_model);
    
    // Buffer for token string
    char buf[256];
    int n = llama_token_to_piece(vocab, p_token, buf, sizeof(buf), 0, false);
    
    if (n < 0) {
        // Token requires more space (shouldn't happen for normal tokens)
        return "";
    }
    
    return String::utf8(buf, n);
}

bool LlamaCppProvider::check_stop_sequences(const String& p_generated, const PackedStringArray& p_stop_seqs) const {
    for (int i = 0; i < p_stop_seqs.size(); i++) {
        if (p_generated.ends_with(p_stop_seqs[i])) {
            return true;
        }
    }
    return false;
}

Ref<LLMGenerationHandle> LlamaCppProvider::generate(const Dictionary& request) {
    Ref<LLMGenerationHandle> handle;
    handle.instantiate();
    
    if (!is_loaded()) {
        handle->set_status(LLMGenerationHandle::STATUS_ERROR);
        handle->call_deferred("_emit_error_deferred", "No model loaded");
        return handle;
    }
    
    // Check if generation is already in progress
    {
        std::lock_guard<std::mutex> lock(m_handle_mutex);
        if (m_worker_running.load(std::memory_order_acquire)) {
            handle->set_status(LLMGenerationHandle::STATUS_ERROR);
            handle->call_deferred("_emit_error_deferred", "Generation already in progress");
            return handle;
        }
    }
    
    // Parse request
    String prompt = request.get("prompt", "");
    String system_prompt = request.get("system_prompt", "");
    int max_tokens = request.get("max_tokens", 256);
    float temperature = request.get("temperature", 0.7f);
    float top_p = request.get("top_p", 0.9f);
    int top_k = request.get("top_k", 40);
    float repeat_penalty = request.get("repeat_penalty", 1.1f);
    PackedStringArray stop_sequences = request.get("stop_sequences", PackedStringArray());
    int seed = request.get("seed", -1);
    
    if (prompt.is_empty()) {
        handle->set_status(LLMGenerationHandle::STATUS_ERROR);
        handle->call_deferred("_emit_error_deferred", "Empty prompt");
        return handle;
    }
    
    handle->set_model_id(m_loaded_model_id);
    handle->start();
    
    {
        std::lock_guard<std::mutex> lock(m_handle_mutex);
        m_current_handle = handle;
    }
    
    m_worker_running.store(true, std::memory_order_release);
    
    // Ensure previous thread is joined
    if (m_worker_thread && m_worker_thread->joinable()) {
        m_worker_thread->join();
    }
    
    // Start generation in background thread
    m_worker_thread = std::make_unique<std::thread>(
        &LlamaCppProvider::_generation_thread_func, this,
        handle, prompt, system_prompt, max_tokens,
        temperature, top_p, top_k, repeat_penalty,
        stop_sequences, seed
    );
    
    return handle;
}

void LlamaCppProvider::_generation_thread_func(
    Ref<LLMGenerationHandle> p_handle,
    String p_prompt,
    String p_system_prompt,
    int p_max_tokens,
    float p_temperature,
    float p_top_p,
    int p_top_k,
    float p_repeat_penalty,
    PackedStringArray p_stop_sequences,
    int p_seed
) {
    // Build full prompt with system prompt if provided
    String full_prompt = p_prompt;
    if (!p_system_prompt.is_empty()) {
        // Use a simple chat format - can be extended for model-specific templates
        full_prompt = "<|im_start|>system\n" + p_system_prompt + "<|im_end|>\n" +
                      "<|im_start|>user\n" + p_prompt + "<|im_end|>\n" +
                      "<|im_start|>assistant\n";
    }
    
    // Tokenize prompt
    std::vector<int32_t> tokens = tokenize(full_prompt, true);
    
    if (tokens.empty()) {
        p_handle->fail("Failed to tokenize prompt");
        m_worker_running.store(false, std::memory_order_release);
        return;
    }
    
    // Check if prompt fits in context
    if (static_cast<int>(tokens.size()) >= m_context_length) {
        p_handle->fail("Prompt too long for context window");
        m_worker_running.store(false, std::memory_order_release);
        return;
    }
    
    // Clear memory (replaces llama_kv_cache_clear)
    llama_memory_clear(llama_get_memory(m_ctx), true);
    
    // Create batch for prompt evaluation
    llama_batch batch = llama_batch_init(tokens.size(), 0, 1);
    
    for (size_t i = 0; i < tokens.size(); i++) {
        batch_add(batch, tokens[i], i, { 0 }, false);
    }
    
    // Mark last token for logits
    batch.logits[batch.n_tokens - 1] = true;
    
    // Evaluate prompt
    if (llama_decode(m_ctx, batch) != 0) {
        llama_batch_free(batch);
        p_handle->fail("Failed to evaluate prompt");
        m_worker_running.store(false, std::memory_order_release);
        return;
    }
    
    llama_batch_free(batch);
    
    // Setup sampler chain
    llama_sampler* sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    
    // Add samplers in order
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(p_top_k));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(p_top_p, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(p_temperature));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(p_seed >= 0 ? p_seed : LLAMA_DEFAULT_SEED));
    
    // Generation loop
    String generated_text;
    int n_cur = tokens.size();
    
    for (int i = 0; i < p_max_tokens; i++) {
        // Check for cancellation
        if (p_handle->is_cancel_requested()) {
            llama_sampler_free(sampler);
            p_handle->mark_cancelled();
            m_worker_running.store(false, std::memory_order_release);
            return;
        }
        
        // Sample next token
        llama_token new_token = llama_sampler_sample(sampler, m_ctx, -1);
        
        // Check for EOS
        const llama_vocab* vocab = llama_model_get_vocab(m_model);
        if (llama_token_is_eog(vocab, new_token)) {
            break;
        }
        
        // Convert token to string
        String token_str = token_to_string(new_token);
        generated_text += token_str;
        
        // Emit token
        p_handle->append_token(token_str);
        
        // Check stop sequences
        if (check_stop_sequences(generated_text, p_stop_sequences)) {
            break;
        }
        
        // Prepare next batch
        llama_batch next_batch = llama_batch_init(1, 0, 1);
        batch_add(next_batch, new_token, n_cur, { 0 }, true);
        n_cur++;
        
        // Evaluate
        if (llama_decode(m_ctx, next_batch) != 0) {
            llama_batch_free(next_batch);
            llama_sampler_free(sampler);
            p_handle->fail("Decode failed during generation");
            m_worker_running.store(false, std::memory_order_release);
            return;
        }
        
        llama_batch_free(next_batch);
    }
    
    llama_sampler_free(sampler);
    
    // Complete
    p_handle->complete(generated_text);
    m_worker_running.store(false, std::memory_order_release);
}

void LlamaCppProvider::cancel(const String& handle_id) {
    std::lock_guard<std::mutex> lock(m_handle_mutex);
    if (m_current_handle.is_valid() && m_current_handle->get_id() == handle_id) {
        m_current_handle->request_cancel();
    }
}

Dictionary LlamaCppProvider::get_status() const {
    Dictionary status;
    
    status["loaded"] = is_loaded();
    status["model_id"] = m_loaded_model_id;
    status["model_path"] = m_loaded_model_path;
    status["context_length"] = m_context_length;
    status["n_threads"] = m_n_threads;
    status["n_gpu_layers"] = m_n_gpu_layers;
    status["generating"] = m_worker_running.load(std::memory_order_acquire);
    
    String backend_name;
    switch (m_backend_type) {
        case BACKEND_CPU: backend_name = "CPU"; break;
        case BACKEND_CUDA: backend_name = "CUDA"; break;
        case BACKEND_METAL: backend_name = "Metal"; break;
        case BACKEND_VULKAN: backend_name = "Vulkan"; break;
        default: backend_name = "Unknown"; break;
    }
    status["backend"] = backend_name;
    
    return status;
}

LlamaCppProvider::BackendType LlamaCppProvider::get_backend_type() const {
    return m_backend_type;
}

int64_t LlamaCppProvider::estimate_memory_usage(const String& model_path) const {
    // Rough estimation: file size + ~20% overhead for context
    // More accurate would require parsing GGUF metadata
    if (!FileAccess::file_exists(model_path)) {
        return -1;
    }
    
    Ref<FileAccess> file = FileAccess::open(model_path, FileAccess::READ);
    if (!file.is_valid()) {
        return -1;
    }
    
    int64_t file_size = file->get_length();
    // Estimate: model weights + context memory
    // Context memory ~= n_ctx * n_embd * 4 * n_layer * 2 (K+V)
    // Simplified: file_size + 20% overhead
    return static_cast<int64_t>(file_size * 1.2);
}

int64_t LlamaCppProvider::get_available_memory() const {
    // Platform-specific memory detection
    // This is a simplified version - could be extended with OS-specific APIs
    Dictionary mem_info = OS::get_singleton()->get_memory_info();
    if (mem_info.has("available")) {
        return mem_info["available"];
    }
    // Fallback: assume 8GB available
    return 8LL * 1024 * 1024 * 1024;
}

int LlamaCppProvider::get_recommended_threads() const {
    int cores = OS::get_singleton()->get_processor_count();
    // Use physical cores (assume hyperthreading = 2x logical)
    int physical = cores / 2;
    if (physical < 1) physical = 1;
    // Cap at 8 for diminishing returns
    return std::min(physical, 8);
}

bool LlamaCppProvider::is_gpu_available() const {
    return m_backend_type != BACKEND_CPU && m_backend_type != BACKEND_UNKNOWN;
}

void LlamaCppProvider::set_n_threads(int p_threads) {
    m_n_threads = std::max(1, p_threads);
}

int LlamaCppProvider::get_n_threads() const {
    return m_n_threads;
}

void LlamaCppProvider::set_n_gpu_layers(int p_layers) {
    m_n_gpu_layers = std::max(0, p_layers);
}

int LlamaCppProvider::get_n_gpu_layers() const {
    return m_n_gpu_layers;
}

} // namespace godot
