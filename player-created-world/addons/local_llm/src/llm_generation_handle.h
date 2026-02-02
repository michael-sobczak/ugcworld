#ifndef LLM_GENERATION_HANDLE_H
#define LLM_GENERATION_HANDLE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <chrono>
#include <mutex>

namespace godot {

/// Handle for an ongoing LLM generation request.
/// Emits signals as tokens stream in, and can be cancelled.
class LLMGenerationHandle : public RefCounted {
    GDCLASS(LLMGenerationHandle, RefCounted);

public:
    enum Status {
        STATUS_PENDING,
        STATUS_RUNNING,
        STATUS_COMPLETED,
        STATUS_CANCELLED,
        STATUS_ERROR
    };

protected:
    static void _bind_methods();

private:
    String m_id;
    String m_model_id;
    Status m_status = STATUS_PENDING;
    std::chrono::steady_clock::time_point m_start_time;
    
    String m_full_text;
    String m_error_message;
    
    std::atomic<bool> m_cancel_requested{false};
    std::mutex m_text_mutex;
    
    int m_tokens_generated = 0;
    double m_elapsed_seconds = 0.0;

public:
    LLMGenerationHandle();
    ~LLMGenerationHandle();

    // Getters
    String get_id() const;
    String get_model_id() const;
    Status get_status() const;
    String get_full_text();
    String get_error_message() const;
    int get_tokens_generated() const;
    double get_elapsed_seconds() const;
    double get_tokens_per_second() const;
    bool is_cancel_requested() const;

    // Setters (called by provider)
    void set_id(const String& p_id);
    void set_model_id(const String& p_model_id);
    void set_status(Status p_status);
    void start();
    
    // Called from worker thread - thread-safe
    void append_token(const String& p_token);
    void complete(const String& p_full_text);
    void fail(const String& p_error);
    void mark_cancelled();
    
    // User-facing
    void request_cancel();
    
    // For deferred signal emission from main thread
    void _emit_token_deferred(const String& p_token);
    void _emit_completed_deferred(const String& p_full_text);
    void _emit_error_deferred(const String& p_error);
    void _emit_cancelled_deferred();
};

} // namespace godot

VARIANT_ENUM_CAST(LLMGenerationHandle::Status);

#endif // LLM_GENERATION_HANDLE_H
