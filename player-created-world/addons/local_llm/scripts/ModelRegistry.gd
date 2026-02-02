## ModelRegistry - Manages available model metadata
##
## Reads from res://models/models.json and provides model information.
## Adding a new model requires only editing models.json and placing the GGUF file.
extends RefCounted
class_name LLMModelRegistry

const MODELS_DIR = "res://models"
const MODELS_JSON = "res://models/models.json"

## Model information structure
## {
##   "id": "qwen2.5-coder-14b-q4_k_m",
##   "display_name": "Qwen 2.5 Coder 14B (Q4_K_M)",
##   "backend": "llama.cpp",
##   "context_length": 32768,
##   "recommended_threads": 8,
##   "quantization": "Q4_K_M",
##   "file_path_in_pck": "res://models/qwen2.5-coder-14b-q4_k_m.gguf",
##   "sha256": "abc123...",
##   "size_bytes": 8500000000,
##   "estimated_memory": 10200000000,
##   "description": "Code generation and understanding model",
##   "tags": ["coding", "14b", "quantized"]
## }

var _models: Dictionary = {}  # id -> model info
var _load_error: String = ""


## Load the model registry from models.json
func load_registry() -> Error:
	_models.clear()
	_load_error = ""
	
	if not FileAccess.file_exists(MODELS_JSON):
		_load_error = "models.json not found at %s" % MODELS_JSON
		return ERR_FILE_NOT_FOUND
	
	var file = FileAccess.open(MODELS_JSON, FileAccess.READ)
	if file == null:
		_load_error = "Failed to open models.json: %s" % error_string(FileAccess.get_open_error())
		return FileAccess.get_open_error()
	
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var err = json.parse(json_text)
	if err != OK:
		_load_error = "Failed to parse models.json: %s at line %d" % [json.get_error_message(), json.get_error_line()]
		return err
	
	var data = json.get_data()
	if not data is Dictionary:
		_load_error = "models.json root must be an object"
		return ERR_INVALID_DATA
	
	var models_array = data.get("models", [])
	if not models_array is Array:
		_load_error = "models.json 'models' must be an array"
		return ERR_INVALID_DATA
	
	for model_data in models_array:
		if not model_data is Dictionary:
			continue
		
		var model_id = model_data.get("id", "")
		if model_id.is_empty():
			push_warning("[LocalLLM] Model entry missing 'id', skipping")
			continue
		
		# Validate required fields
		var required = ["file_path_in_pck", "size_bytes"]
		var valid = true
		for field in required:
			if not model_data.has(field):
				push_warning("[LocalLLM] Model '%s' missing required field '%s'" % [model_id, field])
				valid = false
				break
		
		if valid:
			_models[model_id] = _normalize_model_info(model_data)
	
	print("[LocalLLM] Loaded %d models from registry" % _models.size())
	return OK


## Normalize and fill in defaults for model info
func _normalize_model_info(data: Dictionary) -> Dictionary:
	var info = data.duplicate(true)
	
	# Set defaults
	if not info.has("display_name"):
		info["display_name"] = info["id"]
	
	if not info.has("backend"):
		info["backend"] = "llama.cpp"
	
	if not info.has("context_length"):
		info["context_length"] = 4096
	
	if not info.has("recommended_threads"):
		info["recommended_threads"] = 4
	
	if not info.has("quantization"):
		info["quantization"] = "unknown"
	
	if not info.has("estimated_memory"):
		# Rough estimate: file size + 20% for context
		info["estimated_memory"] = int(info.get("size_bytes", 0) * 1.2)
	
	if not info.has("description"):
		info["description"] = ""
	
	if not info.has("tags"):
		info["tags"] = []
	
	return info


## Get the number of registered models
func get_model_count() -> int:
	return _models.size()


## Get model info by ID
func get_model(model_id: String) -> Dictionary:
	return _models.get(model_id, {})


## List all available models
func list_models() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id in _models:
		result.append(_models[id])
	return result


## Get models filtered by tag
func get_models_by_tag(tag: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id in _models:
		var model = _models[id]
		if tag in model.get("tags", []):
			result.append(model)
	return result


## Get the default/recommended model (first one, or one tagged as default)
func get_default_model() -> Dictionary:
	# Look for explicitly tagged default
	for id in _models:
		var model = _models[id]
		if "default" in model.get("tags", []):
			return model
	
	# Return first model
	if _models.size() > 0:
		return _models.values()[0]
	
	return {}


## Check if a model exists
func has_model(model_id: String) -> bool:
	return _models.has(model_id)


## Get load error message
func get_load_error() -> String:
	return _load_error


## Get memory requirements summary for all models
func get_memory_requirements_summary() -> Dictionary:
	var min_mem = INF
	var max_mem = 0
	
	for id in _models:
		var mem = _models[id].get("estimated_memory", 0)
		if mem > 0:
			min_mem = min(min_mem, mem)
			max_mem = max(max_mem, mem)
	
	if min_mem == INF:
		min_mem = 0
	
	return {
		"min_bytes": min_mem,
		"max_bytes": max_mem,
		"min_gb": min_mem / 1073741824.0,
		"max_gb": max_mem / 1073741824.0
	}
