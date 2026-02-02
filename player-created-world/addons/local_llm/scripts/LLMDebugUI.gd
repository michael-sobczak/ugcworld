## LLMDebugUI - Debug interface for testing Local LLM functionality
##
## Provides a simple UI for:
## - Selecting and loading models
## - Entering prompts
## - Streaming output
## - Viewing generation statistics
extends Control

# UI references (unique names from scene)
@onready var status_label: Label = %StatusLabel
@onready var model_selector: OptionButton = %ModelSelector
@onready var load_button: Button = %LoadButton
@onready var unload_button: Button = %UnloadButton
@onready var memory_label: Label = %MemoryLabel
@onready var prompt_input: TextEdit = %PromptInput
@onready var generate_button: Button = %GenerateButton
@onready var stop_button: Button = %StopButton
@onready var clear_button: Button = %ClearButton
@onready var max_tokens_spinbox: SpinBox = %MaxTokensSpinBox
@onready var temp_spinbox: SpinBox = %TempSpinBox
@onready var output_display: RichTextLabel = %OutputDisplay
@onready var tokens_label: Label = %TokensLabel
@onready var speed_label: Label = %SpeedLabel
@onready var elapsed_label: Label = %ElapsedLabel
@onready var backend_label: Label = %BackendLabel

# State
var _current_handle = null  # LLMGenerationHandle - dynamically typed
var _model_ids: Array[String] = []
var _update_timer: float = 0.0

# Status constants (from LLMGenerationHandle enum)
const STATUS_PENDING = 0
const STATUS_RUNNING = 1
const STATUS_COMPLETED = 2
const STATUS_CANCELLED = 3
const STATUS_ERROR = 4


func _ready() -> void:
	# Connect button signals
	load_button.pressed.connect(_on_load_pressed)
	unload_button.pressed.connect(_on_unload_pressed)
	generate_button.pressed.connect(_on_generate_pressed)
	stop_button.pressed.connect(_on_stop_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	
	# Wait for LocalLLMService to be ready
	await get_tree().process_frame
	
	if not _check_service():
		return
	
	_refresh_model_list()
	_update_status()
	
	# Connect to service signals
	LocalLLMService.model_loading.connect(_on_model_loading)
	LocalLLMService.model_loaded.connect(_on_model_loaded)
	LocalLLMService.model_load_failed.connect(_on_model_load_failed)


func _process(delta: float) -> void:
	# Update stats while generating
	if _current_handle != null and _current_handle.get_status() == STATUS_RUNNING:
		_update_timer += delta
		if _update_timer >= 0.1:  # Update every 100ms
			_update_timer = 0.0
			_update_generation_stats()


func _check_service() -> bool:
	# Check if LocalLLMService autoload exists
	if not Engine.has_singleton("LocalLLMService") and not has_node("/root/LocalLLMService"):
		# Try to get it anyway in case it's there
		pass
	
	var service = get_node_or_null("/root/LocalLLMService")
	if service == null:
		status_label.text = "Status: LocalLLMService not found!"
		status_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
		_set_controls_enabled(false)
		return false
	
	if not service.is_extension_available():
		status_label.text = "Status: GDExtension not built - see docs/LOCAL_LLM.md"
		status_label.add_theme_color_override("font_color", Color(1, 0.5, 0.3))
		output_display.text = "[color=yellow]The LlamaCppProvider GDExtension is not built yet.\n\nTo build it:\n1. Windows: Run scripts/build_llm_win.ps1\n2. Linux: Run scripts/build_llm_linux.sh\n\nSee docs/LOCAL_LLM.md for full instructions.[/color]"
		_set_controls_enabled(false)
		return false
	
	if not service.is_ready():
		status_label.text = "Status: " + service.get_init_error()
		status_label.add_theme_color_override("font_color", Color(1, 0.5, 0.3))
		_set_controls_enabled(false)
		return false
	
	return true


func _refresh_model_list() -> void:
	model_selector.clear()
	_model_ids.clear()
	
	var models = LocalLLMService.list_models()
	
	if models.is_empty():
		model_selector.add_item("No models available")
		model_selector.disabled = true
		load_button.disabled = true
		return
	
	for model in models:
		var display_name = model.get("display_name", model.get("id", "Unknown"))
		var size_gb = model.get("size_bytes", 0) / 1073741824.0
		var label = "%s (%.1f GB)" % [display_name, size_gb]
		
		model_selector.add_item(label)
		_model_ids.append(model.get("id", ""))
	
	model_selector.disabled = false
	load_button.disabled = false
	
	# Select currently loaded model if any
	var loaded_id = LocalLLMService.get_loaded_model_id()
	if not loaded_id.is_empty():
		var idx = _model_ids.find(loaded_id)
		if idx >= 0:
			model_selector.select(idx)


func _update_status() -> void:
	var status = LocalLLMService.get_status()
	
	if status.get("loaded", false):
		var model_id = status.get("model_id", "Unknown")
		status_label.text = "Status: Model loaded - %s" % model_id
		status_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
		
		generate_button.disabled = false
		unload_button.disabled = false
	else:
		status_label.text = "Status: No model loaded"
		status_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
		
		generate_button.disabled = true
		unload_button.disabled = true
	
	# Update backend info
	var backend = status.get("backend", "Unknown")
	var ctx = status.get("context_length", 0)
	var threads = status.get("n_threads", 0)
	backend_label.text = "Backend: %s | ctx=%d | threads=%d" % [backend, ctx, threads]


func _set_controls_enabled(enabled: bool) -> void:
	model_selector.disabled = not enabled
	load_button.disabled = not enabled
	generate_button.disabled = not enabled
	prompt_input.editable = enabled


func _update_generation_stats() -> void:
	if _current_handle == null:
		return
	
	var tokens = _current_handle.get_tokens_generated()
	var elapsed = _current_handle.get_elapsed_seconds()
	var speed = _current_handle.get_tokens_per_second()
	
	tokens_label.text = "Tokens: %d" % tokens
	speed_label.text = "Speed: %.1f t/s" % speed
	elapsed_label.text = "Elapsed: %.1fs" % elapsed


func _on_load_pressed() -> void:
	var idx = model_selector.selected
	if idx < 0 or idx >= _model_ids.size():
		return
	
	var model_id = _model_ids[idx]
	
	# Update memory estimate
	var models = LocalLLMService.list_models()
	for model in models:
		if model.get("id") == model_id:
			var mem_gb = model.get("estimated_memory", 0) / 1073741824.0
			memory_label.text = "Memory: ~%.1f GB required" % mem_gb
			break
	
	load_button.disabled = true
	status_label.text = "Status: Loading model..."
	status_label.add_theme_color_override("font_color", Color(1, 0.8, 0.3))
	
	var result = await LocalLLMService.load_model(model_id)
	
	if not result.success:
		output_display.text = "[color=red]Error loading model: %s[/color]" % result.error


func _on_unload_pressed() -> void:
	LocalLLMService.unload_model()
	_update_status()
	memory_label.text = "Memory: --"


func _on_generate_pressed() -> void:
	var prompt = prompt_input.text.strip_edges()
	if prompt.is_empty():
		output_display.text = "[color=yellow]Please enter a prompt[/color]"
		return
	
	# Clear output
	output_display.clear()
	output_display.text = ""
	
	# Get settings
	var request = {
		"prompt": prompt,
		"max_tokens": int(max_tokens_spinbox.value),
		"temperature": temp_spinbox.value,
		"stream": true
	}
	
	# Start generation
	_current_handle = LocalLLMService.generate_streaming(request)
	
	if _current_handle == null:
		output_display.text = "[color=red]Failed to start generation[/color]"
		return
	
	# Update UI
	generate_button.disabled = true
	stop_button.disabled = false
	prompt_input.editable = false
	
	# Connect signals
	_current_handle.token.connect(_on_token_received)
	_current_handle.completed.connect(_on_generation_completed)
	_current_handle.error.connect(_on_generation_error)
	_current_handle.cancelled.connect(_on_generation_cancelled)
	
	status_label.text = "Status: Generating..."
	status_label.add_theme_color_override("font_color", Color(0.3, 0.8, 1))


func _on_stop_pressed() -> void:
	if _current_handle != null:
		_current_handle.request_cancel()
		status_label.text = "Status: Cancelling..."


func _on_clear_pressed() -> void:
	output_display.clear()
	output_display.text = ""
	tokens_label.text = "Tokens: 0"
	speed_label.text = "Speed: -- t/s"
	elapsed_label.text = "Elapsed: 0.0s"


func _on_token_received(text: String) -> void:
	# Escape BBCode characters for safe display
	var safe_text = text.replace("[", "[lb]").replace("]", "[rb]")
	output_display.append_text(safe_text)


func _on_generation_completed(full_text: String) -> void:
	_finish_generation()
	status_label.text = "Status: Generation complete"
	status_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	_update_generation_stats()


func _on_generation_error(error: String) -> void:
	_finish_generation()
	output_display.append_text("\n[color=red]Error: %s[/color]" % error)
	status_label.text = "Status: Error - " + error
	status_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))


func _on_generation_cancelled() -> void:
	_finish_generation()
	output_display.append_text("\n[color=yellow][Generation cancelled][/color]")
	status_label.text = "Status: Cancelled"
	status_label.add_theme_color_override("font_color", Color(1, 0.8, 0.3))


func _finish_generation() -> void:
	generate_button.disabled = false
	stop_button.disabled = true
	prompt_input.editable = true
	_current_handle = null
	_update_status()


func _on_model_loading(model_id: String) -> void:
	status_label.text = "Status: Loading %s..." % model_id
	status_label.add_theme_color_override("font_color", Color(1, 0.8, 0.3))


func _on_model_loaded(model_id: String) -> void:
	load_button.disabled = false
	_update_status()


func _on_model_load_failed(model_id: String, error: String) -> void:
	load_button.disabled = false
	status_label.text = "Status: Load failed - " + error
	status_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
