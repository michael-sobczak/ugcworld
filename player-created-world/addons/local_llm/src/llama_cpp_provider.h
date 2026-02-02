#ifndef LLAMA_CPP_PROVIDER_H
#define LLAMA_CPP_PROVIDER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/thread.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include "llm_generation_handle.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>

// Forward declarations for llama.cpp
struct llama_model;
struct llama_context;
struct llama_sampler;

namespace godot {

/// Provider implementation for llama.cpp backend.
/// Handles model loading, inference, and streaming.
class LlamaCppProvider : public RefCounted {
    GDCLASS(LlamaCppProvider, RefCounted);

public:
    enum BackendType {
        BACKEND_CPU,
        BACKEND_CUDA,
        BACKEND_METAL,
        BACKEND_VULKAN,
        BACKEND_UNKNOWN
    };

protected:
    static void _bind_methods();

private:
    // llama.cpp state
    llama_model* m_model = nullptr;
    llama_context* m_ctx = nullptr;
    
    // Model info
    String m_loaded_model_id;
    String m_loaded_model_path;
    int m_context_length = 0;
    int m_n_threads = 4;
    int m_n_gpu_layers = 0;
    
    // Thread management
    std::unique_ptr<std::thread> m_worker_thread;
    std::atomic<bool> m_worker_running{false};
    std::mutex m_model_mutex;
    
    // Current generation
    Ref<LLMGenerationHandle> m_current_handle;
    std::mutex m_handle_mutex;
    
    // Backend detection
    BackendType m_backend_type = BACKEND_CPU;
    
    // Logging helper
    void log_info(const String& p_message) const;
    void log_error(const String& p_message) const;
    void log_warning(const String& p_message) const;
    
    // Internal generation loop
    void _generation_thread_func(
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
    );
    
    // Tokenization helpers
    std::vector<int32_t> tokenize(const String& p_text, bool p_add_bos) const;
    String token_to_string(int32_t p_token) const;
    
    // Check if token matches any stop sequence
    bool check_stop_sequences(const String& p_generated, const PackedStringArray& p_stop_seqs) const;

public:
    LlamaCppProvider();
    ~LlamaCppProvider();

    // ILLMProvider interface methods
    
    /// Check if a model is currently loaded
    bool is_loaded() const;
    
    /// Get the ID of the currently loaded model
    String get_loaded_model_id() const;
    
    /// Load a model from the given filesystem path
    /// @param model_path Absolute path to the GGUF file
    /// @param model_id Identifier for this model
    /// @param context_length Maximum context length
    /// @param n_threads Number of CPU threads to use
    /// @param n_gpu_layers Number of layers to offload to GPU (0 = CPU only)
    /// @return true on success, false on failure
    bool load_model(
        const String& model_path,
        const String& model_id,
        int context_length,
        int n_threads,
        int n_gpu_layers
    );
    
    /// Unload the current model and free resources
    void unload_model();
    
    /// Generate text from a prompt
    /// @param request Dictionary containing generation parameters
    /// @return LLMGenerationHandle for tracking and cancellation
    Ref<LLMGenerationHandle> generate(const Dictionary& request);
    
    /// Cancel an ongoing generation by handle ID
    void cancel(const String& handle_id);
    
    /// Get provider status information
    Dictionary get_status() const;
    
    /// Get detected backend type
    BackendType get_backend_type() const;
    
    /// Get memory estimate for a model
    /// @param model_path Path to the GGUF file
    /// @return Estimated memory usage in bytes, or -1 on error
    int64_t estimate_memory_usage(const String& model_path) const;
    
    /// Get available system memory
    int64_t get_available_memory() const;
    
    /// Detect optimal thread count
    int get_recommended_threads() const;
    
    /// Check if GPU acceleration is available
    bool is_gpu_available() const;
    
    // Thread count accessors
    void set_n_threads(int p_threads);
    int get_n_threads() const;
    
    // GPU layers accessors
    void set_n_gpu_layers(int p_layers);
    int get_n_gpu_layers() const;
};

} // namespace godot

VARIANT_ENUM_CAST(LlamaCppProvider::BackendType);

#endif // LLAMA_CPP_PROVIDER_H
