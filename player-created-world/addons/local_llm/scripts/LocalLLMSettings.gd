## LocalLLMSettings - Persistent settings for Local LLM
##
## Stores user preferences for model selection, thread count, etc.
## Saved to user://local_llm_settings.json
extends RefCounted
class_name LLMSettings

const SETTINGS_PATH = "user://local_llm_settings.json"

## Currently selected model ID
var selected_model_id: String = ""

## Number of CPU threads to use (0 = auto-detect)
var n_threads: int = 0

## Context length (0 = use model default)
var context_length: int = 0

## Number of GPU layers to offload (0 = CPU only)
var n_gpu_layers: int = 0

## Default max tokens for generation
var max_tokens_default: int = 512

## Whether to auto-load the last used model on startup
var auto_load_last_model: bool = false

## Temperature default
var temperature_default: float = 0.7

## Top-p default
var top_p_default: float = 0.9


## Load settings from disk
func load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		print("[LocalLLM] No settings file found, using defaults")
		return
	
	var file = FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if file == null:
		push_warning("[LocalLLM] Failed to open settings file")
		return
	
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var err = json.parse(json_text)
	if err != OK:
		push_warning("[LocalLLM] Failed to parse settings: %s" % json.get_error_message())
		return
	
	var data = json.get_data()
	if not data is Dictionary:
		push_warning("[LocalLLM] Settings file has invalid format")
		return
	
	# Load values with type checking
	if data.has("selected_model_id") and data["selected_model_id"] is String:
		selected_model_id = data["selected_model_id"]
	
	if data.has("n_threads") and (data["n_threads"] is int or data["n_threads"] is float):
		n_threads = int(data["n_threads"])
	
	if data.has("context_length") and (data["context_length"] is int or data["context_length"] is float):
		context_length = int(data["context_length"])
	
	if data.has("n_gpu_layers") and (data["n_gpu_layers"] is int or data["n_gpu_layers"] is float):
		n_gpu_layers = int(data["n_gpu_layers"])
	
	if data.has("max_tokens_default") and (data["max_tokens_default"] is int or data["max_tokens_default"] is float):
		max_tokens_default = int(data["max_tokens_default"])
	
	if data.has("auto_load_last_model") and data["auto_load_last_model"] is bool:
		auto_load_last_model = data["auto_load_last_model"]
	
	if data.has("temperature_default") and (data["temperature_default"] is int or data["temperature_default"] is float):
		temperature_default = float(data["temperature_default"])
	
	if data.has("top_p_default") and (data["top_p_default"] is int or data["top_p_default"] is float):
		top_p_default = float(data["top_p_default"])
	
	print("[LocalLLM] Settings loaded")


## Save settings to disk
func save_settings() -> void:
	var data = {
		"selected_model_id": selected_model_id,
		"n_threads": n_threads,
		"context_length": context_length,
		"n_gpu_layers": n_gpu_layers,
		"max_tokens_default": max_tokens_default,
		"auto_load_last_model": auto_load_last_model,
		"temperature_default": temperature_default,
		"top_p_default": top_p_default
	}
	
	var json_text = JSON.stringify(data, "\t")
	
	var file = FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[LocalLLM] Failed to save settings: %s" % error_string(FileAccess.get_open_error()))
		return
	
	file.store_string(json_text)
	file.close()
	
	print("[LocalLLM] Settings saved")


## Reset to defaults
func reset_to_defaults() -> void:
	selected_model_id = ""
	n_threads = 0
	context_length = 0
	n_gpu_layers = 0
	max_tokens_default = 512
	auto_load_last_model = false
	temperature_default = 0.7
	top_p_default = 0.9
	save_settings()


## Get settings as dictionary
func to_dict() -> Dictionary:
	return {
		"selected_model_id": selected_model_id,
		"n_threads": n_threads,
		"context_length": context_length,
		"n_gpu_layers": n_gpu_layers,
		"max_tokens_default": max_tokens_default,
		"auto_load_last_model": auto_load_last_model,
		"temperature_default": temperature_default,
		"top_p_default": top_p_default
	}
