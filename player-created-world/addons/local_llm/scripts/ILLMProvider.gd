## ILLMProvider - Interface for LLM provider implementations
##
## This class defines the contract that all LLM providers must implement.
## While GDScript doesn't have formal interfaces, this serves as documentation
## and can be used for duck-typing validation.
##
## To add a new provider backend:
## 1. Create a class that implements all methods defined here
## 2. Register it with LocalLLMService
##
## Current implementations:
## - LlamaCppProvider (GDExtension, C++) - for GGUF models via llama.cpp
##
## Future potential implementations:
## - OllamaProvider - for Ollama server integration
## - ONNXProvider - for ONNX runtime models
## - RemoteProvider - for API-based fallback
extends RefCounted
class_name ILLMProvider

## Model information structure
## Return this from list_models() and get_model_info()
const MODEL_INFO_TEMPLATE = {
	"id": "",                    # Unique model identifier
	"display_name": "",          # Human-readable name
	"backend": "",               # Provider backend (e.g., "llama.cpp")
	"context_length": 4096,      # Maximum context window
	"recommended_threads": 4,    # Suggested thread count
	"quantization": "",          # Quantization method if applicable
	"file_path": "",             # Path to model file
	"sha256": "",                # File hash for verification
	"size_bytes": 0,             # File size
	"estimated_memory": 0,       # RAM requirement estimate
	"description": "",           # Model description
	"tags": []                   # Searchable tags
}

## Provider status structure
## Return this from get_status()
const STATUS_TEMPLATE = {
	"loaded": false,             # Whether a model is loaded
	"model_id": "",              # Currently loaded model ID
	"model_path": "",            # Path to loaded model
	"context_length": 0,         # Active context length
	"n_threads": 0,              # Active thread count
	"n_gpu_layers": 0,           # GPU layers offloaded
	"generating": false,         # Whether generation is in progress
	"backend": ""                # Backend type (CPU, CUDA, Metal, etc.)
}

## Request structure for generate()
const REQUEST_TEMPLATE = {
	"prompt": "",                # Required: Input text
	"system_prompt": "",         # Optional: System instructions
	"max_tokens": 512,           # Maximum tokens to generate
	"temperature": 0.7,          # Sampling temperature (0.0-2.0)
	"top_p": 0.9,                # Nucleus sampling threshold
	"top_k": 40,                 # Top-k sampling
	"repeat_penalty": 1.1,       # Repetition penalty
	"stop_sequences": [],        # Stop generation strings
	"seed": -1,                  # Random seed (-1 for random)
	"stream": true               # Enable token streaming
}


# ============================================================================
# INTERFACE METHODS - Must be implemented by providers
# ============================================================================

## Check if a model is currently loaded
## @return true if a model is loaded and ready for inference
func is_loaded() -> bool:
	push_error("ILLMProvider.is_loaded() not implemented")
	return false


## Get the ID of the currently loaded model
## @return Model ID or empty string if none loaded
func get_loaded_model_id() -> String:
	push_error("ILLMProvider.get_loaded_model_id() not implemented")
	return ""


## Load a model for inference
## @param model_path Filesystem path to model file
## @param model_id Identifier for this model
## @param context_length Maximum context window size
## @param n_threads Number of CPU threads to use
## @param n_gpu_layers Number of layers to offload to GPU
## @return true on success, false on failure
func load_model(
	model_path: String,
	model_id: String,
	context_length: int,
	n_threads: int,
	n_gpu_layers: int
) -> bool:
	push_error("ILLMProvider.load_model() not implemented")
	return false


## Unload the current model and free resources
func unload_model() -> void:
	push_error("ILLMProvider.unload_model() not implemented")


## Generate text from a request
## @param request Dictionary containing generation parameters (see REQUEST_TEMPLATE)
## @return LLMGenerationHandle (or compatible object) for tracking progress and cancellation
func generate(request: Dictionary):  # Returns LLMGenerationHandle
	push_error("ILLMProvider.generate() not implemented")
	return null


## Cancel an ongoing generation
## @param handle_id The ID of the generation handle to cancel
func cancel(handle_id: String) -> void:
	push_error("ILLMProvider.cancel() not implemented")


## Get provider status information
## @return Dictionary containing status info (see STATUS_TEMPLATE)
func get_status() -> Dictionary:
	push_error("ILLMProvider.get_status() not implemented")
	return STATUS_TEMPLATE.duplicate()


## Estimate memory usage for a model
## @param model_path Path to the model file
## @return Estimated memory in bytes, or -1 on error
func estimate_memory_usage(model_path: String) -> int:
	push_error("ILLMProvider.estimate_memory_usage() not implemented")
	return -1


## Get available system memory
## @return Available memory in bytes
func get_available_memory() -> int:
	push_error("ILLMProvider.get_available_memory() not implemented")
	return 0


## Get recommended thread count for this system
## @return Recommended number of threads
func get_recommended_threads() -> int:
	push_error("ILLMProvider.get_recommended_threads() not implemented")
	return 4


## Check if GPU acceleration is available
## @return true if GPU can be used
func is_gpu_available() -> bool:
	push_error("ILLMProvider.is_gpu_available() not implemented")
	return false


# ============================================================================
# VALIDATION HELPERS
# ============================================================================

## Validate that an object implements the ILLMProvider interface
## @param obj Object to validate
## @return true if object has all required methods
static func validate_provider(obj: Object) -> bool:
	if obj == null:
		return false
	
	var required_methods = [
		"is_loaded",
		"get_loaded_model_id",
		"load_model",
		"unload_model",
		"generate",
		"cancel",
		"get_status",
		"get_recommended_threads",
		"is_gpu_available"
	]
	
	for method in required_methods:
		if not obj.has_method(method):
			push_warning("Provider missing method: %s" % method)
			return false
	
	return true


## Validate a request dictionary
## @param request Request to validate
## @return Array of validation error messages (empty if valid)
static func validate_request(request: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	
	if not request.has("prompt"):
		errors.append("Missing required field: prompt")
	elif request["prompt"].strip_edges().is_empty():
		errors.append("Prompt cannot be empty")
	
	if request.has("temperature"):
		var temp = request["temperature"]
		if temp < 0.0 or temp > 2.0:
			errors.append("Temperature must be between 0.0 and 2.0")
	
	if request.has("top_p"):
		var top_p = request["top_p"]
		if top_p < 0.0 or top_p > 1.0:
			errors.append("top_p must be between 0.0 and 1.0")
	
	if request.has("max_tokens"):
		var max_tokens = request["max_tokens"]
		if max_tokens < 1:
			errors.append("max_tokens must be at least 1")
	
	return errors
