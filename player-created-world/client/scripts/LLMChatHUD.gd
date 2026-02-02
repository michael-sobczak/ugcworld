## LLM Chat HUD - Player interface for interacting with local LLM
extends CanvasLayer

# UI References
@onready var chat_panel: PanelContainer = $ChatPanel
@onready var input_field: TextEdit = $ChatPanel/VBox/InputContainer/InputField
@onready var send_button: Button = $ChatPanel/VBox/InputContainer/SendButton
@onready var output_label: RichTextLabel = $ChatPanel/VBox/OutputScroll/OutputLabel
@onready var status_label: Label = $ChatPanel/VBox/StatusBar/StatusLabel
@onready var toggle_button: Button = $ToggleButton
@onready var loading_indicator: Label = $ChatPanel/VBox/StatusBar/LoadingIndicator

var _is_generating: bool = false
var _current_handle = null


func _ready() -> void:
	# Connect UI signals
	send_button.pressed.connect(_on_send_pressed)
	toggle_button.pressed.connect(_on_toggle_pressed)
	input_field.gui_input.connect(_on_input_gui_input)
	
	# Connect to LocalLLMService signals
	if LocalLLMService.is_extension_available():
		LocalLLMService.model_loaded.connect(_on_model_loaded)
		LocalLLMService.model_unloaded.connect(_on_model_unloaded)
		LocalLLMService.generation_started.connect(_on_generation_started)
		LocalLLMService.generation_completed.connect(_on_generation_completed)
		LocalLLMService.generation_failed.connect(_on_generation_failed)
	
	# Initial state
	chat_panel.visible = false
	_update_status()


func _on_toggle_pressed() -> void:
	chat_panel.visible = not chat_panel.visible
	if chat_panel.visible:
		input_field.grab_focus()
		toggle_button.text = "✕"
	else:
		toggle_button.text = "💬"


func _on_input_gui_input(event: InputEvent) -> void:
	# Submit on Ctrl+Enter or Shift+Enter
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ENTER and (event.ctrl_pressed or event.shift_pressed):
			_on_send_pressed()
			get_viewport().set_input_as_handled()


func _on_send_pressed() -> void:
	if _is_generating:
		_cancel_generation()
		return
	
	var prompt = input_field.text.strip_edges()
	if prompt.is_empty():
		return
	
	if not LocalLLMService.is_extension_available():
		_append_output("[color=red]LLM extension not available. Build the extension first.[/color]\n")
		return
	
	if not LocalLLMService.is_model_loaded():
		_append_output("[color=yellow]No model loaded. Loading default model...[/color]\n")
		await _load_default_model()
		if not LocalLLMService.is_model_loaded():
			_append_output("[color=red]Failed to load model.[/color]\n")
			return
	
	# Show user message
	_append_output("[color=cyan][b]You:[/b][/color] %s\n\n" % prompt)
	
	# Clear input
	input_field.text = ""
	
	# Start generation
	_is_generating = true
	send_button.text = "⬛ Stop"
	loading_indicator.visible = true
	
	_append_output("[color=lime][b]AI:[/b][/color] ")
	
	# Generate with streaming
	_current_handle = LocalLLMService.generate_streaming({
		"prompt": prompt,
		"max_tokens": 512,
		"temperature": 0.7
	})
	
	if _current_handle == null:
		_append_output("[color=red]Failed to start generation[/color]\n\n")
		_generation_finished()
		return
	
	# Connect to streaming tokens
	_current_handle.token.connect(_on_token_received)
	_current_handle.completed.connect(_on_handle_completed)
	_current_handle.error.connect(_on_handle_error)
	_current_handle.cancelled.connect(_on_handle_cancelled)


func _on_token_received(token: String) -> void:
	# Append each token as it arrives
	output_label.append_text(token)
	# Auto-scroll to bottom
	await get_tree().process_frame
	output_label.scroll_to_line(output_label.get_line_count())


func _on_handle_completed(_text: String) -> void:
	_append_output("\n\n")
	_generation_finished()


func _on_handle_error(error: String) -> void:
	_append_output("\n[color=red]Error: %s[/color]\n\n" % error)
	_generation_finished()


func _on_handle_cancelled() -> void:
	_append_output("\n[color=gray](cancelled)[/color]\n\n")
	_generation_finished()


func _cancel_generation() -> void:
	if _current_handle != null:
		LocalLLMService.cancel_generation(_current_handle.get_id())


func _generation_finished() -> void:
	_is_generating = false
	_current_handle = null
	send_button.text = "Send"
	loading_indicator.visible = false
	_update_status()


func _on_model_loaded(model_id: String) -> void:
	_update_status()
	_append_output("[color=green]Model loaded: %s[/color]\n\n" % model_id)


func _on_model_unloaded() -> void:
	_update_status()


func _on_generation_started(_handle_id: String) -> void:
	pass


func _on_generation_completed(_handle_id: String, _text: String) -> void:
	pass


func _on_generation_failed(_handle_id: String, _error: String) -> void:
	pass


func _append_output(text: String) -> void:
	output_label.append_text(text)
	# Auto-scroll
	await get_tree().process_frame
	output_label.scroll_to_line(output_label.get_line_count())


func _update_status() -> void:
	if not LocalLLMService.is_extension_available():
		status_label.text = "⚠ Extension not loaded"
		status_label.modulate = Color.ORANGE
		return
	
	if LocalLLMService.is_model_loaded():
		var model_id = LocalLLMService.get_loaded_model_id()
		status_label.text = "✓ %s" % model_id
		status_label.modulate = Color.LIME
	else:
		status_label.text = "○ No model loaded"
		status_label.modulate = Color.GRAY


func _load_default_model() -> void:
	var models = LocalLLMService.list_models()
	if models.is_empty():
		_append_output("[color=red]No models available in registry.[/color]\n")
		return
	
	# Try to load first available model
	var model_id = models[0].get("id", "")
	if model_id.is_empty():
		return
	
	_append_output("[color=gray]Loading %s...[/color]\n" % model_id)
	var result = await LocalLLMService.load_model(model_id)
	if not result.success:
		_append_output("[color=red]%s[/color]\n" % result.get("error", "Unknown error"))
