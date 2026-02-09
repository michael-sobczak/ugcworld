## Model Selection Dialog - choose a local LLM to load
## Autoloads: LocalLLMService
extends CanvasLayer

signal model_selected(model_id: String)
signal dialog_closed

@onready var panel: PanelContainer = $Panel
@onready var model_list: ItemList = $Panel/VBox/ModelList
@onready var refresh_btn: Button = $Panel/VBox/ButtonRow/RefreshBtn
@onready var load_btn: Button = $Panel/VBox/ButtonRow/LoadBtn
@onready var cancel_btn: Button = $Panel/VBox/ButtonRow/CancelBtn
@onready var status_label: Label = $Panel/VBox/StatusLabel

var _models: Array[Dictionary] = []
const _DEBUG_RUN_ID := "spell_model_load"
var _debug_log_path: String = ""


func _ready() -> void:
	refresh_btn.pressed.connect(_on_refresh_pressed)
	load_btn.pressed.connect(_on_load_pressed)
	cancel_btn.pressed.connect(_on_cancel_pressed)
	model_list.item_activated.connect(_on_item_activated)
	
	visible = false
	_debug_log_path = _resolve_debug_log_path()
	_debug_log("H1", "ready", {
		"extension_available": LocalLLMService.is_extension_available(),
		"log_path": _debug_log_path
	})
	_refresh_models()


func show_dialog() -> void:
	visible = true
	_debug_log("H1", "show_dialog", {
		"extension_available": LocalLLMService.is_extension_available(),
		"log_path": _debug_log_path
	})
	_refresh_models()
	load_btn.grab_focus()


func hide_dialog() -> void:
	visible = false
	dialog_closed.emit()


func _refresh_models() -> void:
	model_list.clear()
	_models = []
	_debug_log("H1", "refresh_models_start", {"extension_available": LocalLLMService.is_extension_available()})
	
	if not LocalLLMService.is_extension_available():
		_set_status("Local LLM extension not available.", Color.RED)
		load_btn.disabled = true
		_debug_log("H1", "refresh_models_no_extension", {})
		return
	
	_models = LocalLLMService.list_models()
	if _models.is_empty():
		_set_status("No models found in models.json", Color.ORANGE)
		load_btn.disabled = true
		_debug_log("H2", "refresh_models_empty", {})
		return
	
	for model_info in _models:
		var model_id: String = model_info.get("id", "")
		var display_name: String = model_info.get("display_name", model_id)
		var quant: String = model_info.get("quantization", "")
		var mem_bytes: int = model_info.get("estimated_memory", 0)
		
		var label := display_name
		if not quant.is_empty():
			label += " - " + quant
		if mem_bytes > 0:
			label += " (%.1f GB)" % (mem_bytes / 1073741824.0)
		
		var idx := model_list.add_item(label)
		model_list.set_item_metadata(idx, model_id)
	
	load_btn.disabled = false
	_set_status("Select a model to load", Color.WHITE)
	_debug_log("H1", "refresh_models_done", {"model_count": _models.size()})


func _on_refresh_pressed() -> void:
	_refresh_models()


func _on_item_activated(_index: int) -> void:
	_on_load_pressed()


func _on_load_pressed() -> void:
	var selected := model_list.get_selected_items()
	if selected.is_empty():
		_set_status("Select a model first", Color.ORANGE)
		_debug_log("H2", "load_pressed_no_selection", {})
		return
	
	var model_id = model_list.get_item_metadata(selected[0])
	if typeof(model_id) != TYPE_STRING or String(model_id).is_empty():
		_set_status("Invalid model selection", Color.RED)
		_debug_log("H2", "load_pressed_invalid_selection", {"model_id": model_id})
		return
	
	load_btn.disabled = true
	refresh_btn.disabled = true
	_set_status("Loading model: %s..." % model_id, Color.CYAN)
	_debug_log("H3", "load_model_start", {"model_id": model_id})
	
	var result: Dictionary = await LocalLLMService.load_model(model_id)
	load_btn.disabled = false
	refresh_btn.disabled = false
	
	if result.get("success", false):
		_set_status("Loaded: %s" % model_id, Color.LIME)
		_debug_log("H3", "load_model_success", {"model_id": model_id})
		hide_dialog()
		model_selected.emit(model_id)
	else:
		var error_message: String = String(result.get("error", "Failed to load model"))
		_set_status(error_message, Color.RED)
		_debug_log("H4", "load_model_failed", {"model_id": model_id, "error": error_message})


func _on_cancel_pressed() -> void:
	hide_dialog()


func _set_status(message: String, color: Color) -> void:
	status_label.text = message
	status_label.modulate = color


func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			hide_dialog()
			get_viewport().set_input_as_handled()


func _debug_log(hypothesis_id: String, message: String, data: Dictionary) -> void:
	# region agent log
	if _debug_log_path.is_empty():
		return
	var payload := {
		"id": "%s_%s_%d" % [hypothesis_id, message, Time.get_ticks_msec()],
		"timestamp": Time.get_ticks_msec(),
		"location": "ModelSelectionDialog.gd",
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
