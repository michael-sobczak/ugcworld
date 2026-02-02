#ifndef LOCAL_LLM_REGISTER_TYPES_H
#define LOCAL_LLM_REGISTER_TYPES_H

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void initialize_local_llm_module(ModuleInitializationLevel p_level);
void uninitialize_local_llm_module(ModuleInitializationLevel p_level);

#endif // LOCAL_LLM_REGISTER_TYPES_H
