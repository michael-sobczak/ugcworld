#include "llm_generation_handle.h"

#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

void LLMGenerationHandle::_bind_methods() {
    // Signals
    ADD_SIGNAL(MethodInfo("token", PropertyInfo(Variant::STRING, "text_chunk")));
    ADD_SIGNAL(MethodInfo("completed", PropertyInfo(Variant::STRING, "full_text")));
    ADD_SIGNAL(MethodInfo("error", PropertyInfo(Variant::STRING, "message")));
    ADD_SIGNAL(MethodInfo("cancelled"));

    // Getters
    ClassDB::bind_method(D_METHOD("get_id"), &LLMGenerationHandle::get_id);
    ClassDB::bind_method(D_METHOD("get_model_id"), &LLMGenerationHandle::get_model_id);
    ClassDB::bind_method(D_METHOD("get_status"), &LLMGenerationHandle::get_status);
    ClassDB::bind_method(D_METHOD("get_full_text"), &LLMGenerationHandle::get_full_text);
    ClassDB::bind_method(D_METHOD("get_error_message"), &LLMGenerationHandle::get_error_message);
    ClassDB::bind_method(D_METHOD("get_tokens_generated"), &LLMGenerationHandle::get_tokens_generated);
    ClassDB::bind_method(D_METHOD("get_elapsed_seconds"), &LLMGenerationHandle::get_elapsed_seconds);
    ClassDB::bind_method(D_METHOD("get_tokens_per_second"), &LLMGenerationHandle::get_tokens_per_second);
    ClassDB::bind_method(D_METHOD("is_cancel_requested"), &LLMGenerationHandle::is_cancel_requested);
    
    // Actions
    ClassDB::bind_method(D_METHOD("request_cancel"), &LLMGenerationHandle::request_cancel);
    
    // Internal deferred methods
    ClassDB::bind_method(D_METHOD("_emit_token_deferred", "token"), &LLMGenerationHandle::_emit_token_deferred);
    ClassDB::bind_method(D_METHOD("_emit_completed_deferred", "full_text"), &LLMGenerationHandle::_emit_completed_deferred);
    ClassDB::bind_method(D_METHOD("_emit_error_deferred", "error"), &LLMGenerationHandle::_emit_error_deferred);
    ClassDB::bind_method(D_METHOD("_emit_cancelled_deferred"), &LLMGenerationHandle::_emit_cancelled_deferred);

    // Enum
    BIND_ENUM_CONSTANT(STATUS_PENDING);
    BIND_ENUM_CONSTANT(STATUS_RUNNING);
    BIND_ENUM_CONSTANT(STATUS_COMPLETED);
    BIND_ENUM_CONSTANT(STATUS_CANCELLED);
    BIND_ENUM_CONSTANT(STATUS_ERROR);

    // Properties
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "id"), "", "get_id");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "model_id"), "", "get_model_id");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "status"), "", "get_status");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "tokens_generated"), "", "get_tokens_generated");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "elapsed_seconds"), "", "get_elapsed_seconds");
}

LLMGenerationHandle::LLMGenerationHandle() {
    // Generate unique ID
    m_id = String::num_int64(Time::get_singleton()->get_ticks_usec()) + "_" + 
           String::num_int64(OS::get_singleton()->get_process_id());
}

LLMGenerationHandle::~LLMGenerationHandle() {
    // Request cancellation if still running
    if (m_status == STATUS_RUNNING) {
        m_cancel_requested.store(true, std::memory_order_release);
    }
}

String LLMGenerationHandle::get_id() const {
    return m_id;
}

String LLMGenerationHandle::get_model_id() const {
    return m_model_id;
}

LLMGenerationHandle::Status LLMGenerationHandle::get_status() const {
    return m_status;
}

String LLMGenerationHandle::get_full_text() {
    std::lock_guard<std::mutex> lock(m_text_mutex);
    return m_full_text;
}

String LLMGenerationHandle::get_error_message() const {
    return m_error_message;
}

int LLMGenerationHandle::get_tokens_generated() const {
    return m_tokens_generated;
}

double LLMGenerationHandle::get_elapsed_seconds() const {
    if (m_status == STATUS_RUNNING) {
        auto now = std::chrono::steady_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(now - m_start_time);
        return duration.count() / 1000.0;
    }
    return m_elapsed_seconds;
}

double LLMGenerationHandle::get_tokens_per_second() const {
    double elapsed = get_elapsed_seconds();
    if (elapsed > 0.0 && m_tokens_generated > 0) {
        return m_tokens_generated / elapsed;
    }
    return 0.0;
}

bool LLMGenerationHandle::is_cancel_requested() const {
    return m_cancel_requested.load(std::memory_order_acquire);
}

void LLMGenerationHandle::set_id(const String& p_id) {
    m_id = p_id;
}

void LLMGenerationHandle::set_model_id(const String& p_model_id) {
    m_model_id = p_model_id;
}

void LLMGenerationHandle::set_status(Status p_status) {
    m_status = p_status;
}

void LLMGenerationHandle::start() {
    m_status = STATUS_RUNNING;
    m_start_time = std::chrono::steady_clock::now();
    m_tokens_generated = 0;
    {
        std::lock_guard<std::mutex> lock(m_text_mutex);
        m_full_text = "";
    }
}

void LLMGenerationHandle::append_token(const String& p_token) {
    {
        std::lock_guard<std::mutex> lock(m_text_mutex);
        m_full_text += p_token;
    }
    m_tokens_generated++;
    
    // Emit signal on main thread
    call_deferred("_emit_token_deferred", p_token);
}

void LLMGenerationHandle::complete(const String& p_full_text) {
    m_status = STATUS_COMPLETED;
    auto now = std::chrono::steady_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(now - m_start_time);
    m_elapsed_seconds = duration.count() / 1000.0;
    
    {
        std::lock_guard<std::mutex> lock(m_text_mutex);
        m_full_text = p_full_text;
    }
    
    call_deferred("_emit_completed_deferred", p_full_text);
}

void LLMGenerationHandle::fail(const String& p_error) {
    m_status = STATUS_ERROR;
    m_error_message = p_error;
    auto now = std::chrono::steady_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(now - m_start_time);
    m_elapsed_seconds = duration.count() / 1000.0;
    
    call_deferred("_emit_error_deferred", p_error);
}

void LLMGenerationHandle::mark_cancelled() {
    m_status = STATUS_CANCELLED;
    auto now = std::chrono::steady_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(now - m_start_time);
    m_elapsed_seconds = duration.count() / 1000.0;
    
    call_deferred("_emit_cancelled_deferred");
}

void LLMGenerationHandle::request_cancel() {
    m_cancel_requested.store(true, std::memory_order_release);
    UtilityFunctions::print("[LocalLLM] Cancellation requested for handle: ", m_id);
}

void LLMGenerationHandle::_emit_token_deferred(const String& p_token) {
    emit_signal("token", p_token);
}

void LLMGenerationHandle::_emit_completed_deferred(const String& p_full_text) {
    emit_signal("completed", p_full_text);
}

void LLMGenerationHandle::_emit_error_deferred(const String& p_error) {
    emit_signal("error", p_error);
}

void LLMGenerationHandle::_emit_cancelled_deferred() {
    emit_signal("cancelled");
}

} // namespace godot
