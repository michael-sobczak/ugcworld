## LocalLLMService - Main autoload singleton for Local LLM functionality
##
## This service provides a high-level API for LLM inference.
## It manages providers, model loading, extraction, and generation requests.
##
## Usage:
##     # Get the service (autoloaded as LocalLLMService)
##     var result = await LocalLLMService.generate("Write a hello world in Python")
##     print(result.text)
##
##     # With streaming
##     var handle = LocalLLMService.generate_streaming({
##         "prompt": "Explain recursion",
##         "max_tokens": 256
##     })
##     handle.token.connect(func(chunk): print(chunk))
##     await handle.completed
extends Node

const ModelRegistry = preload("res://addons/local_llm/scripts/ModelRegistry.gd")
const ModelExtractor = preload("res://addons/local_llm/scripts/ModelExtractor.gd")
const LocalLLMSettings = preload("res://addons/local_llm/scripts/LocalLLMSettings.gd")

## Emitted when a model starts loading
signal model_loading(model_id: String)

## Emitted when a model finishes loading
signal model_loaded(model_id: String)

## Emitted when a model fails to load
signal model_load_failed(model_id: String, error: String)

## Emitted when a model is unloaded
signal model_unloaded()

## Emitted when generation starts
signal generation_started(handle_id: String)

## Emitted when generation completes
signal generation_completed(handle_id: String, text: String)

## Emitted when generation fails
signal generation_failed(handle_id: String, error: String)


# Internal state
var _registry: ModelRegistry
var _extractor: ModelExtractor
var _settings: LocalLLMSettings
var _provider  # LlamaCppProvider - dynamically typed to handle missing extension
var _is_ready: bool = false
var _init_error: String = ""
var _extension_available: bool = false
const _DEBUG_RUN_ID := "spell_model_load"
var _debug_log_path: String = ""


func _ready() -> void:
	_log("Initializing LocalLLMService...")
	_debug_log_path = _resolve_debug_log_path()
	_debug_log("H1", "service_ready_start", {"debug_log_path": _debug_log_path})
	
	# Check if the GDExtension is loaded
	_extension_available = ClassDB.class_exists("LlamaCppProvider")
	
	if not _extension_available:
		_init_error = "LlamaCppProvider GDExtension not loaded. Build the extension first using scripts/build_llm_win.ps1 or scripts/build_llm_linux.sh"
		_log_error(_init_error)
		_log_warning("LocalLLMService running in stub mode - no LLM functionality available")
		_debug_log("H1", "extension_missing", {"init_error": _init_error})
	
	# Initialize components (these work without the extension)
	_registry = ModelRegistry.new()
	_extractor = ModelExtractor.new()
	_settings = LocalLLMSettings.new()
	
	# Load settings
	_settings.load_settings()
	
	# Initialize provider only if extension is available
	if _extension_available:
		_provider = ClassDB.instantiate("LlamaCppProvider")
		if _provider == null:
			_init_error = "Failed to create LlamaCppProvider instance"
			_log_error(_init_error)
			return
	
	# Load model registry
	var err = _registry.load_registry()
	if err != OK:
		_log_warning("No models.json found - no embedded models available")
		_debug_log("H2", "registry_load_failed", {"error_code": err})
	
	_is_ready = _extension_available
	
	if _is_ready:
		_log("LocalLLMService ready. Available models: %d" % _registry.get_model_count())
		_debug_log("H2", "service_ready", {
			"models_count": _registry.get_model_count(),
			"selected_model_id": _settings.selected_model_id
		})
		
		# Auto-load model on startup only if the user opted in
		if _settings.auto_load_last_model and not _settings.selected_model_id.is_empty():
			_debug_log("H3", "auto_load_last_model", {"model_id": _settings.selected_model_id})
			call_deferred("_auto_load_model")
		else:
			_log("Skipping auto-load (auto_load_last_model=%s, selected=%s)" % [
				str(_settings.auto_load_last_model), _settings.selected_model_id
			])
	else:
		_log("LocalLLMService initialized (extension not available)")
		_debug_log("H1", "service_not_ready", {"extension_available": _extension_available})


func _exit_tree() -> void:
	if _provider != null and _provider.is_loaded():
		_provider.unload_model()
	if _settings != null:
		_settings.save_settings()


func _auto_load_model() -> void:
	var model_info = _registry.get_model(_settings.selected_model_id)
	if model_info != null and not model_info.is_empty():
		_log("Auto-loading last used model: %s" % _settings.selected_model_id)
		_debug_log("H3", "auto_load_model_start", {"model_id": _settings.selected_model_id})
		await load_model(_settings.selected_model_id)
	else:
		_debug_log("H3", "auto_load_model_missing_info", {"model_id": _settings.selected_model_id})


func _auto_load_default_model() -> void:
	var default_model = _registry.get_default_model()
	if default_model.is_empty():
		_log("No default model found to auto-load")
		_debug_log("H3", "auto_load_default_missing", {})
		return
	
	var model_id = default_model.get("id", "")
	if model_id.is_empty():
		_debug_log("H3", "auto_load_default_empty_id", {})
		return
	
	_log("Auto-loading default model: %s" % model_id)
	_debug_log("H3", "auto_load_default_start", {"model_id": model_id})
	await load_model(model_id)


# ============================================================================
# PUBLIC API
# ============================================================================

## Check if the service is ready to use
func is_ready() -> bool:
	return _is_ready


## Check if the native extension is available
func is_extension_available() -> bool:
	return _extension_available


## Get initialization error if not ready
func get_init_error() -> String:
	return _init_error


## Get the model registry
func get_registry() -> ModelRegistry:
	return _registry


## Get current settings
func get_settings() -> LocalLLMSettings:
	return _settings


## Get provider status information
func get_status() -> Dictionary:
	if _provider == null:
		return {
			"loaded": false,
			"error": "Provider not initialized",
			"extension_available": _extension_available
		}
	return _provider.get_status()


## Check if a model is currently loaded
func is_model_loaded() -> bool:
	return _provider != null and _provider.is_loaded()


## Get the currently loaded model ID
func get_loaded_model_id() -> String:
	if _provider == null:
		return ""
	return _provider.get_loaded_model_id()


## List all available models
func list_models() -> Array[Dictionary]:
	return _registry.list_models()


## Load a model by ID
## Extracts from PCK if needed and loads into memory
func load_model(model_id: String) -> Dictionary:
	if _provider == null:
		_debug_log("H1", "load_model_no_provider", {"model_id": model_id})
		return {"success": false, "error": "Provider not initialized - extension not loaded"}
	
	var model_info = _registry.get_model(model_id)
	if model_info == null or model_info.is_empty():
		_debug_log("H2", "load_model_missing_info", {"model_id": model_id})
		return {"success": false, "error": "Model not found: %s" % model_id}
	
	model_loading.emit(model_id)
	_log("Loading model: %s" % model_id)
	_debug_log("H3", "load_model_start", {
		"model_id": model_id,
		"provider_loaded": _provider.is_loaded(),
		"loaded_model_id": _provider.get_loaded_model_id()
	})
	
	# Check memory requirements
	var required_mem = model_info.get("estimated_memory", model_info.get("size_bytes", 0) * 1.2)
	var available_mem = _provider.get_available_memory()
	_debug_log("H3", "load_model_memory_check", {"required_mem": required_mem, "available_mem": available_mem})
	
	if required_mem > available_mem * 0.9:  # Leave 10% headroom
		var error = "Insufficient memory. Required: %.1f GB, Available: %.1f GB" % [
			required_mem / 1073741824.0,
			available_mem / 1073741824.0
		]
		_debug_log("H3", "load_model_insufficient_memory", {"error": error})
		model_load_failed.emit(model_id, error)
		return {"success": false, "error": error}
	
	# Extract model if needed
	var extract_result = await _extractor.ensure_extracted(model_info)
	if not extract_result.success:
		_debug_log("H4", "load_model_extract_failed", {"error": extract_result.error})
		model_load_failed.emit(model_id, extract_result.error)
		return {"success": false, "error": extract_result.error}
	
	var model_path = extract_result.path
	_debug_log("H4", "load_model_extract_ok", {"model_path": model_path})
	
	# Determine context length.
	# models.json stores the model's *maximum* context (e.g. 163840).
	# Allocating full context eats tens of GB of KV-cache RAM, so we cap
	# to a sane default unless the user explicitly configured a value.
	const MAX_DEFAULT_CONTEXT := 4096
	var context_len: int = _settings.context_length
	if context_len <= 0:
		var model_max: int = model_info.get("context_length", 4096)
		context_len = mini(model_max, MAX_DEFAULT_CONTEXT)
		_log("Context length: using %d (model max %d, cap %d)" % [context_len, model_max, MAX_DEFAULT_CONTEXT])
	
	var n_threads = _settings.n_threads
	if n_threads <= 0:
		n_threads = _provider.get_recommended_threads()
	
	var n_gpu_layers = _settings.n_gpu_layers
	if not _provider.is_gpu_available():
		n_gpu_layers = 0
	
	_debug_log("H3", "load_model_settings", {
		"context_len": context_len,
		"n_threads": n_threads,
		"n_gpu_layers": n_gpu_layers,
		"gpu_available": _provider.is_gpu_available()
	})
	
	# Unload current model if any
	if _provider.is_loaded():
		_debug_log("H3", "load_model_unload_existing", {"loaded_model_id": _provider.get_loaded_model_id()})
		_provider.unload_model()
		model_unloaded.emit()
	
	# Load the model
	var success = _provider.load_model(
		model_path, 
		model_id, 
		context_len, 
		n_threads, 
		n_gpu_layers
	)
	
	if success:
		_debug_log("H5", "load_model_success", {"model_id": model_id})
		_settings.selected_model_id = model_id
		_settings.save_settings()
		model_loaded.emit(model_id)
		_log("Model loaded successfully: %s" % model_id)
		return {"success": true}
	else:
		var error = "Failed to load model - check logs for details"
		_debug_log("H5", "load_model_failed_provider", {"model_id": model_id, "error": error})
		model_load_failed.emit(model_id, error)
		return {"success": false, "error": error}


func _debug_log(hypothesis_id: String, message: String, data: Dictionary) -> void:
	# region agent log
	if _debug_log_path.is_empty():
		return
	var payload := {
		"id": "%s_%s_%d" % [hypothesis_id, message, Time.get_ticks_msec()],
		"timestamp": Time.get_ticks_msec(),
		"location": "LocalLLMService.gd",
		"message": message,
		"data": data,
		"runId": _DEBUG_RUN_ID,
		"hypothesisId": hypothesis_id
	}
	var file := FileAccess.open(_debug_log_path, FileAccess.WRITE_READ)
	if file != null:
		file.seek_end()
		file.store_line(JSON.stringify(payload))
		file.close()
	# endregion agent log


func _resolve_debug_log_path() -> String:
	var project_root := ProjectSettings.globalize_path("res://")
	var repo_root := project_root.get_base_dir()
	var config_path := repo_root.path_join("debug_config.json")
	
	if FileAccess.file_exists(config_path):
		var file := FileAccess.open(config_path, FileAccess.READ)
		if file != null:
			var text := file.get_as_text()
			file.close()
			
			var json := JSON.new()
			var parse_err := json.parse(text)
			if parse_err == OK and json.data is Dictionary:
				var value_str: String = String(json.data.get("debug_log_path", ""))
				if not value_str.is_empty():
					return value_str
	
	return ProjectSettings.globalize_path("user://debug.log")


## Unload the current model
func unload_model() -> void:
	if _provider != null and _provider.is_loaded():
		_provider.unload_model()
		model_unloaded.emit()
		_log("Model unloaded")


## Generate text (blocking, returns full result)
## For streaming, use generate_streaming()
func generate(prompt: String, options: Dictionary = {}) -> Dictionary:
	var request = options.duplicate()
	request["prompt"] = prompt
	request["stream"] = false
	
	var handle = generate_streaming(request)
	if handle == null:
		return {"success": false, "error": "Failed to start generation"}
	
	# Wait for completion
	var result = await _wait_for_handle(handle)
	return result


## Generate text with streaming (returns handle immediately)
## Returns null if provider not available
func generate_streaming(request: Dictionary):  # -> LLMGenerationHandle or null
	if _provider == null:
		_log_error("Provider not initialized")
		return null
	
	if not _provider.is_loaded():
		_log_error("No model loaded")
		return null
	
	# Apply default settings
	var full_request = {
		"prompt": request.get("prompt", ""),
		"system_prompt": request.get("system_prompt", ""),
		"max_tokens": request.get("max_tokens", _settings.max_tokens_default),
		"temperature": request.get("temperature", 0.7),
		"top_p": request.get("top_p", 0.9),
		"top_k": request.get("top_k", 40),
		"repeat_penalty": request.get("repeat_penalty", 1.1),
		"stop_sequences": request.get("stop_sequences", PackedStringArray()),
		"seed": request.get("seed", -1),
		"stream": request.get("stream", true)
	}
	
	var handle = _provider.generate(full_request)
	
	if handle != null:
		generation_started.emit(handle.get_id())
		
		# Connect signals for service-level events
		handle.completed.connect(func(text): generation_completed.emit(handle.get_id(), text))
		handle.error.connect(func(err): generation_failed.emit(handle.get_id(), err))
	
	return handle


## Cancel an ongoing generation
func cancel_generation(handle_id: String) -> void:
	if _provider != null:
		_provider.cancel(handle_id)


## Estimate token count for a string (rough estimate)
func estimate_tokens(text: String) -> int:
	# Rough estimate: ~4 characters per token for English
	# This is imprecise but useful for planning
	return max(1, text.length() / 4)


## Get recommended thread count for this system
func get_recommended_threads() -> int:
	if _provider != null:
		return _provider.get_recommended_threads()
	# Fallback: use half of logical processors, capped at 8
	var cores = OS.get_processor_count()
	return min(max(1, cores / 2), 8)


## Check if GPU acceleration is available
func is_gpu_available() -> bool:
	if _provider != null:
		return _provider.is_gpu_available()
	return false


# ============================================================================
# INTERNAL HELPERS
# ============================================================================

func _wait_for_handle(handle) -> Dictionary:  # handle: LLMGenerationHandle
	var result = {"success": false, "text": "", "error": ""}
	
	if handle == null:
		result.error = "Invalid handle"
		return result
	
	var on_complete = func(text: String):
		result.success = true
		result.text = text
		result.tokens_generated = handle.get_tokens_generated()
		result.elapsed_seconds = handle.get_elapsed_seconds()
		result.tokens_per_second = handle.get_tokens_per_second()
	
	var on_error = func(error: String):
		result.error = error
	
	var on_cancelled = func():
		result.error = "Generation cancelled"
	
	handle.completed.connect(on_complete)
	handle.error.connect(on_error)
	handle.cancelled.connect(on_cancelled)
	
	# Wait for any terminal state
	# Status constants: 0=PENDING, 1=RUNNING, 2=COMPLETED, 3=CANCELLED, 4=ERROR
	while handle.get_status() == 0 or handle.get_status() == 1:
		await get_tree().process_frame
	
	return result


func _log(message: String) -> void:
	print("[LocalLLM] %s" % message)


func _log_error(message: String) -> void:
	push_error("[LocalLLM] %s" % message)


func _log_warning(message: String) -> void:
	push_warning("[LocalLLM] %s" % message)
