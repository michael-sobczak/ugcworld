## Spell Creation Screen - LLM-assisted spell description drafting
## Autoloads: LocalLLMService
extends CanvasLayer

const DESCRIPTION_PROMPT_PATH := "res://client/prompts/generate_spell_description.md"
const ASSET_PROMPT_PATH := "res://client/prompts/generate_spell_asset_manifest.md"
const PARTICLE_PROMPT_PATH := "res://client/prompts/generate_particle_effect.md"
const SHAPE_PROMPT_PATH := "res://client/prompts/generate_simple_shapes.md"
const SANITIZE_PROMPT_PATH := "res://client/prompts/sanitize_gdscript.md"
const OUTPUT_TITLE_DESCRIPTION := "Spell Description"
const OUTPUT_TITLE_ASSETS := "Asset Manifest"

@onready var panel: PanelContainer = $Panel
@onready var close_button: Button = $Panel/VBox/Header/CloseButton
@onready var input_field: TextEdit = $Panel/VBox/InputContainer/InputField
@onready var send_button: Button = $Panel/VBox/InputContainer/SendButton
@onready var output_root: VBoxContainer = $Panel/VBox/OutputScroll/OutputRoot
@onready var status_label: Label = $Panel/VBox/StatusBar/StatusLabel

var _description_prompt: String = ""
var _asset_prompt: String = ""
var _particle_prompt: String = ""
var _shape_prompt: String = ""
var _sanitize_prompt: String = ""
var _is_generating: bool = false
var _current_handle: Object = null
var _loaded_model_id: String = ""

## Parsed asset manifest entries: Array of {type, description}
var _asset_entries: Array[Dictionary] = []
## Per-asset generated code keyed by index (particles) or "shapes" (merged shapes)
var _asset_results: Dictionary = {}
## UI references for asset table rows keyed same way
var _asset_row_refs: Dictionary = {}
## Container for the asset table
var _asset_table_container: VBoxContainer = null
## Container for asset generation output (below table)
var _asset_gen_container: VBoxContainer = null
## Currently previewed particle instance (for cleanup)
var _preview_instance: Node = null


func _ready() -> void:
	send_button.pressed.connect(_on_send_pressed)
	close_button.pressed.connect(_on_close_pressed)
	input_field.gui_input.connect(_on_input_gui_input)

	visible = false
	_description_prompt = _load_prompt(DESCRIPTION_PROMPT_PATH)
	_asset_prompt = _load_prompt(ASSET_PROMPT_PATH)
	_particle_prompt = _load_prompt(PARTICLE_PROMPT_PATH)
	_shape_prompt = _load_prompt(SHAPE_PROMPT_PATH)
	_sanitize_prompt = _load_prompt(SANITIZE_PROMPT_PATH)
	_update_status("")


func show_screen(model_id: String) -> void:
	_loaded_model_id = model_id
	visible = true
	_clear_outputs()
	_asset_entries.clear()
	_asset_results.clear()
	_asset_row_refs.clear()
	_asset_table_container = null
	_asset_gen_container = null
	_cleanup_preview()
	input_field.text = ""
	input_field.grab_focus()
	_update_status("Ready")


func hide_screen() -> void:
	_cleanup_preview()
	visible = false


func _on_close_pressed() -> void:
	hide_screen()


func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER:
			_on_send_pressed()
			get_viewport().set_input_as_handled()


func _on_send_pressed() -> void:
	if _is_generating:
		return

	var prompt := input_field.text.strip_edges()
	if prompt.is_empty():
		return

	if not LocalLLMService.is_extension_available():
		_show_message_panel("Error", "Local LLM extension not available. Build the extension first.")
		return

	if not LocalLLMService.is_model_loaded():
		_show_message_panel("Error", "No model loaded. Press S to select a model.")
		return

	var model_id := LocalLLMService.get_loaded_model_id()
	if not _loaded_model_id.is_empty() and model_id != _loaded_model_id:
		_loaded_model_id = model_id

	_is_generating = true
	send_button.disabled = true
	_update_status("Generating description...")
	_clear_outputs()
	_asset_entries.clear()
	_asset_results.clear()
	_asset_row_refs.clear()
	_asset_table_container = null
	_asset_gen_container = null
	_cleanup_preview()

	var description_panel := _create_output_panel(OUTPUT_TITLE_DESCRIPTION, output_root)
	_current_handle = _start_generation(
		prompt,
		_description_prompt,
		description_panel,
		"description"
	)

	if _current_handle == null:
		_generation_finished("Failed to start generation")
		return


func _on_token_received(token: String, panel_data: Dictionary) -> void:
	var label: RichTextLabel = panel_data.get("text_label")
	if label == null:
		return
	label.append_text(token)
	await get_tree().process_frame
	label.scroll_to_line(label.get_line_count())


func _on_generation_completed(text: String, panel_data: Dictionary, stage: String) -> void:
	if stage == "description":
		_update_status("Generating asset manifest...")
		var children_box: VBoxContainer = panel_data.get("children_box")
		var asset_panel := _create_output_panel(OUTPUT_TITLE_ASSETS, children_box)
		_current_handle = _start_generation(
			text,
			_asset_prompt,
			asset_panel,
			"assets"
		)
		if _current_handle == null:
			_generation_finished("Failed to start asset generation")
	elif stage == "assets":
		_parse_and_build_asset_table(text)
		_generation_finished("Done - select assets below")
	elif stage == "asset_gen":
		_generation_finished("Asset generated")
	else:
		_generation_finished("Done")


func _on_generation_error(message: String, panel_data: Dictionary, _stage: String) -> void:
	var label: RichTextLabel = panel_data.get("text_label")
	if label:
		label.append_text("\n\n[Error] %s" % message)
	_generation_finished("Error")


func _on_generation_cancelled(panel_data: Dictionary, _stage: String) -> void:
	var label: RichTextLabel = panel_data.get("text_label")
	if label:
		label.append_text("\n\n[Cancelled]")
	_generation_finished("Cancelled")


func _generation_finished(status: String) -> void:
	_is_generating = false
	send_button.disabled = false
	_update_status(status)


func _update_status(message: String) -> void:
	var model_id := LocalLLMService.get_loaded_model_id()
	var status := "Model: "
	if model_id.is_empty():
		status += "None"
	else:
		status += model_id

	if not message.is_empty():
		status += " | " + message

	if _description_prompt.is_empty():
		status += " | Missing description prompt"
	if _asset_prompt.is_empty():
		status += " | Missing asset prompt"

	status_label.text = status


func _load_prompt(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""

	var text := file.get_as_text()
	file.close()
	return text


func _clear_outputs() -> void:
	_cleanup_preview()
	for child in output_root.get_children():
		output_root.remove_child(child)
		child.queue_free()


func _show_message_panel(title: String, message: String) -> void:
	_clear_outputs()
	var msg_panel := _create_output_panel(title, output_root)
	var label: RichTextLabel = msg_panel.get("text_label")
	if label:
		label.text = message


func _create_output_panel(title: String, parent_container: VBoxContainer) -> Dictionary:
	var panel_container := PanelContainer.new()
	panel_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var panel_vbox := VBoxContainer.new()
	panel_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_vbox.add_theme_constant_override("separation", 6)
	panel_container.add_child(panel_vbox)

	# Header row with title and toggle button
	var header_row := HBoxContainer.new()
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_vbox.add_child(header_row)

	var title_label := Label.new()
	title_label.text = title
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(title_label)

	var toggle_btn := Button.new()
	toggle_btn.text = "Show"
	toggle_btn.custom_minimum_size = Vector2(60, 0)
	header_row.add_child(toggle_btn)

	# Content wrapper (hidden by default, shown via toggle)
	var content_wrapper := VBoxContainer.new()
	content_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_wrapper.visible = false
	panel_vbox.add_child(content_wrapper)

	var text_label := RichTextLabel.new()
	text_label.bbcode_enabled = false
	text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text_label.fit_content = true
	text_label.scroll_following = true
	text_label.selection_enabled = true
	content_wrapper.add_child(text_label)

	var indent := MarginContainer.new()
	indent.add_theme_constant_override("margin_left", 16)
	indent.add_theme_constant_override("margin_top", 8)
	content_wrapper.add_child(indent)

	var children_box := VBoxContainer.new()
	children_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	children_box.add_theme_constant_override("separation", 8)
	indent.add_child(children_box)

	# Wire toggle button
	toggle_btn.pressed.connect(func() -> void:
		content_wrapper.visible = not content_wrapper.visible
		toggle_btn.text = "Hide" if content_wrapper.visible else "Show"
	)

	parent_container.add_child(panel_container)

	return {
		"container": panel_container,
		"text_label": text_label,
		"children_box": children_box,
		"content_wrapper": content_wrapper,
		"toggle_btn": toggle_btn
	}


func _start_generation(
	prompt: String,
	system_prompt: String,
	panel_data: Dictionary,
	stage: String
) -> Object:
	var handle = LocalLLMService.generate_streaming({
		"prompt": prompt,
		"system_prompt": system_prompt,
		"max_tokens": 1024,
		"temperature": 0.7
	})

	if handle == null:
		return null

	handle.token.connect(_on_token_received.bind(panel_data))
	handle.completed.connect(_on_generation_completed.bind(panel_data, stage))
	handle.error.connect(_on_generation_error.bind(panel_data, stage))
	handle.cancelled.connect(_on_generation_cancelled.bind(panel_data, stage))

	return handle


func _cleanup_preview() -> void:
	if _preview_instance != null and is_instance_valid(_preview_instance):
		_preview_instance.queue_free()
		_preview_instance = null


# ============================================================================
# Asset Table
# ============================================================================

func _parse_and_build_asset_table(manifest_text: String) -> void:
	_asset_entries.clear()
	_asset_results.clear()
	_asset_row_refs.clear()

	# Try to extract JSON array from the LLM output
	var json_text := _extract_json_array(manifest_text)
	var json := JSON.new()
	var err := json.parse(json_text)
	if err != OK:
		_show_asset_table_error("Failed to parse asset manifest JSON: %s" % json.get_error_message())
		return

	var data = json.get_data()
	if not data is Array:
		_show_asset_table_error("Asset manifest is not an array")
		return

	for entry in data:
		if entry is Dictionary:
			var entry_type: String = str(entry.get("type", "unknown"))
			var entry_desc: String = str(entry.get("description", ""))
			_asset_entries.append({"type": entry_type, "description": entry_desc})

	if _asset_entries.is_empty():
		_show_asset_table_error("No assets found in manifest")
		return

	_build_asset_table_ui()


func _extract_json_array(text: String) -> String:
	var start := text.find("[")
	var end := text.rfind("]")
	if start >= 0 and end > start:
		return text.substr(start, end - start + 1)
	return text


func _show_asset_table_error(message: String) -> void:
	if _asset_table_container != null:
		return
	_asset_table_container = VBoxContainer.new()
	_asset_table_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	output_root.add_child(_asset_table_container)

	var lbl := Label.new()
	lbl.text = "Asset Table Error: %s" % message
	lbl.modulate = Color.RED
	_asset_table_container.add_child(lbl)


func _build_asset_table_ui() -> void:
	_asset_table_container = VBoxContainer.new()
	_asset_table_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_asset_table_container.add_theme_constant_override("separation", 4)
	output_root.add_child(_asset_table_container)

	var title := Label.new()
	title.text = "Assets"
	title.add_theme_font_size_override("font_size", 16)
	_asset_table_container.add_child(title)

	var header := _create_table_row("Type", "Asset", "Description", true)
	_asset_table_container.add_child(header)

	var shape_indices: Array[int] = []
	for i in range(_asset_entries.size()):
		if _asset_entries[i]["type"] == "shape":
			shape_indices.append(i)

	var shape_row_built := false
	for i in range(_asset_entries.size()):
		var entry: Dictionary = _asset_entries[i]
		var entry_type: String = entry["type"]
		var entry_desc: String = entry["description"]

		if entry_type == "shape":
			if not shape_row_built:
				var combined_desc := ""
				for si in shape_indices:
					var sd: String = _asset_entries[si]["description"]
					combined_desc += "- %s\n" % sd
				var row := _create_asset_row("shape", "shapes", combined_desc.strip_edges(), shape_indices.size())
				_asset_table_container.add_child(row)
				shape_row_built = true
		else:
			var row := _create_asset_row(entry_type, str(i), entry_desc, 1)
			_asset_table_container.add_child(row)

	var sep := HSeparator.new()
	_asset_table_container.add_child(sep)

	_asset_gen_container = VBoxContainer.new()
	_asset_gen_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_asset_gen_container.add_theme_constant_override("separation", 8)
	_asset_table_container.add_child(_asset_gen_container)


func _create_table_row(col1: String, col2: String, col3: String, is_header: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)

	var lbl1 := Label.new()
	lbl1.text = col1
	lbl1.custom_minimum_size = Vector2(80, 0)
	if is_header:
		lbl1.add_theme_font_size_override("font_size", 13)
		lbl1.modulate = Color(0.7, 0.85, 1.0)
	row.add_child(lbl1)

	var lbl2 := Label.new()
	lbl2.text = col2
	lbl2.custom_minimum_size = Vector2(100, 0)
	if is_header:
		lbl2.add_theme_font_size_override("font_size", 13)
		lbl2.modulate = Color(0.7, 0.85, 1.0)
	row.add_child(lbl2)

	var lbl3 := Label.new()
	lbl3.text = col3
	lbl3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl3.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if is_header:
		lbl3.add_theme_font_size_override("font_size", 13)
		lbl3.modulate = Color(0.7, 0.85, 1.0)
	row.add_child(lbl3)

	return row


func _create_asset_row(asset_type: String, key: String, description: String, count: int) -> PanelContainer:
	var row_panel := PanelContainer.new()
	row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)
	row_panel.add_child(row)

	var type_label := Label.new()
	type_label.custom_minimum_size = Vector2(80, 0)
	if asset_type == "shape":
		type_label.text = "shape (%d)" % count
	else:
		type_label.text = asset_type
	row.add_child(type_label)

	var asset_box := HBoxContainer.new()
	asset_box.custom_minimum_size = Vector2(100, 0)
	row.add_child(asset_box)

	var select_btn := Button.new()
	select_btn.text = "Select"
	select_btn.custom_minimum_size = Vector2(70, 0)
	asset_box.add_child(select_btn)

	var asset_status := Label.new()
	asset_status.text = ""
	asset_status.visible = false
	asset_box.add_child(asset_status)

	var desc_label := Label.new()
	desc_label.text = description
	desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(desc_label)

	_asset_row_refs[key] = {
		"panel": row_panel,
		"select_btn": select_btn,
		"asset_status": asset_status,
		"type": asset_type,
		"description": description,
		"key": key
	}

	select_btn.pressed.connect(_on_asset_select_pressed.bind(key))

	return row_panel


func _on_asset_select_pressed(key: String) -> void:
	if _is_generating:
		return

	var row_ref: Dictionary = _asset_row_refs.get(key, {})
	if row_ref.is_empty():
		return

	var asset_type: String = row_ref.get("type", "")
	var description: String = row_ref.get("description", "")

	# Clear previous generation output
	_cleanup_preview()
	if _asset_gen_container != null:
		for child in _asset_gen_container.get_children():
			_asset_gen_container.remove_child(child)
			child.queue_free()

	var system_prompt: String = ""
	var user_prompt: String = ""
	if asset_type == "particle":
		system_prompt = _particle_prompt
		user_prompt = description
	elif asset_type == "shape":
		system_prompt = _shape_prompt
		user_prompt = description
	else:
		user_prompt = description

	if system_prompt.is_empty():
		_update_status("Missing prompt for asset type: %s" % asset_type)
		return

	_is_generating = true
	send_button.disabled = true
	_update_status("Generating %s asset..." % asset_type)

	if asset_type == "particle":
		_start_particle_asset_generation(user_prompt, system_prompt, key)
	else:
		# Shape or other: use the existing text-only flow
		var gen_title := "Generating: %s" % asset_type
		if asset_type == "shape":
			gen_title = "Generating: shapes (merged)"

		var gen_panel := _create_output_panel(gen_title, _asset_gen_container)
		var content_wrapper: VBoxContainer = gen_panel.get("content_wrapper")
		var toggle_btn: Button = gen_panel.get("toggle_btn")
		if content_wrapper != null:
			content_wrapper.visible = true
		if toggle_btn != null:
			toggle_btn.text = "Hide"

		_current_handle = _start_asset_generation(
			user_prompt,
			system_prompt,
			gen_panel,
			key
		)

		if _current_handle == null:
			_generation_finished("Failed to start asset generation")


func _start_asset_generation(
	prompt: String,
	system_prompt: String,
	panel_data: Dictionary,
	asset_key: String
) -> Object:
	var handle = LocalLLMService.generate_streaming({
		"prompt": prompt,
		"system_prompt": system_prompt,
		"max_tokens": 1024,
		"temperature": 0.7
	})

	if handle == null:
		return null

	handle.token.connect(_on_token_received.bind(panel_data))
	handle.completed.connect(_on_asset_gen_completed.bind(panel_data, asset_key))
	handle.error.connect(_on_generation_error.bind(panel_data, asset_key))
	handle.cancelled.connect(_on_generation_cancelled.bind(panel_data, asset_key))

	return handle


func _on_asset_gen_completed(text: String, _panel_data: Dictionary, asset_key: String) -> void:
	var code := _extract_gdscript(text)

	# Run LLM sanitization pass if prompt is available
	if not _sanitize_prompt.is_empty() and LocalLLMService.is_model_loaded():
		_update_status("Sanitizing generated code...")
		var sanitized := await _run_sanitize_pass(code)
		if not sanitized.is_empty():
			code = sanitized

	_asset_results[asset_key] = code
	_mark_row_selected(asset_key)
	_generation_finished("Asset generated")


func _mark_row_selected(asset_key: String) -> void:
	var row_ref: Dictionary = _asset_row_refs.get(asset_key, {})
	if row_ref.is_empty():
		return

	var row_panel: PanelContainer = row_ref.get("panel")
	var select_btn: Button = row_ref.get("select_btn")
	var asset_status: Label = row_ref.get("asset_status")

	if row_panel != null:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.2, 0.4, 0.2, 0.6)
		style.set_corner_radius_all(4)
		row_panel.add_theme_stylebox_override("panel", style)

	if select_btn != null:
		select_btn.text = "Reselect"
	if asset_status != null:
		asset_status.text = "Generated"
		asset_status.modulate = Color.LIME
		asset_status.visible = true


# ============================================================================
# Particle Asset – Preview + Editable Code
# ============================================================================

func _start_particle_asset_generation(description: String, system_prompt: String, asset_key: String) -> void:
	if _asset_gen_container == null:
		_generation_finished("No asset generation container")
		return

	# Build the particle asset UI container
	var particle_ui := _build_particle_asset_ui(asset_key)
	_asset_gen_container.add_child(particle_ui.container)

	# Start streaming into the hidden RichTextLabel
	var streaming_label: RichTextLabel = particle_ui.streaming_label

	var handle = LocalLLMService.generate_streaming({
		"prompt": description,
		"system_prompt": system_prompt,
		"max_tokens": 1024,
		"temperature": 0.7
	})

	if handle == null:
		_generation_finished("Failed to start particle generation")
		return

	# Stream tokens into the streaming label
	var stream_panel: Dictionary = {"text_label": streaming_label}
	handle.token.connect(_on_token_received.bind(stream_panel))
	handle.completed.connect(_on_particle_gen_completed.bind(particle_ui, asset_key))
	handle.error.connect(func(msg: String) -> void:
		particle_ui.error_label.text = "Generation error: %s" % msg
		particle_ui.error_label.visible = true
		_generation_finished("Particle generation error")
	)
	handle.cancelled.connect(func() -> void:
		particle_ui.error_label.text = "Generation cancelled"
		particle_ui.error_label.visible = true
		_generation_finished("Cancelled")
	)

	_current_handle = handle


## Holds references to all the particle UI widgets for one asset key
class ParticleAssetUI:
	var container: VBoxContainer
	var preview_panel: PanelContainer
	var preview_viewport: SubViewport
	var preview_viewport_container: SubViewportContainer
	var code_wrapper: VBoxContainer
	var code_editor: TextEdit
	var code_toggle_btn: Button
	var recompile_btn: Button
	var error_label: Label
	var streaming_label: RichTextLabel
	var play_btn: Button
	var asset_key: String


func _build_particle_asset_ui(asset_key: String) -> ParticleAssetUI:
	var ui := ParticleAssetUI.new()
	ui.asset_key = asset_key

	# Root container
	ui.container = VBoxContainer.new()
	ui.container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui.container.add_theme_constant_override("separation", 8)

	# --- Title row ---
	var title_row := HBoxContainer.new()
	title_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui.container.add_child(title_row)

	var title_lbl := Label.new()
	title_lbl.text = "Particle Effect Preview"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_font_size_override("font_size", 15)
	title_row.add_child(title_lbl)

	# --- Preview panel with SubViewport ---
	ui.preview_panel = PanelContainer.new()
	ui.preview_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui.preview_panel.custom_minimum_size = Vector2(0, 200)
	var preview_style := StyleBoxFlat.new()
	preview_style.bg_color = Color(0.05, 0.05, 0.08, 1.0)
	preview_style.set_corner_radius_all(6)
	ui.preview_panel.add_theme_stylebox_override("panel", preview_style)
	ui.container.add_child(ui.preview_panel)

	ui.preview_viewport_container = SubViewportContainer.new()
	ui.preview_viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui.preview_viewport_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ui.preview_viewport_container.stretch = true
	ui.preview_panel.add_child(ui.preview_viewport_container)

	ui.preview_viewport = SubViewport.new()
	ui.preview_viewport.size = Vector2i(400, 200)
	ui.preview_viewport.transparent_bg = true
	ui.preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	ui.preview_viewport_container.add_child(ui.preview_viewport)

	# --- Button row ---
	var btn_row := HBoxContainer.new()
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_theme_constant_override("separation", 8)
	ui.container.add_child(btn_row)

	ui.play_btn = Button.new()
	ui.play_btn.text = "Play Effect"
	ui.play_btn.disabled = true
	btn_row.add_child(ui.play_btn)

	ui.code_toggle_btn = Button.new()
	ui.code_toggle_btn.text = "Show Code"
	btn_row.add_child(ui.code_toggle_btn)

	ui.recompile_btn = Button.new()
	ui.recompile_btn.text = "Compile & Preview"
	ui.recompile_btn.visible = false
	btn_row.add_child(ui.recompile_btn)

	# --- Error label ---
	ui.error_label = Label.new()
	ui.error_label.text = ""
	ui.error_label.visible = false
	ui.error_label.modulate = Color.RED
	ui.error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ui.error_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui.container.add_child(ui.error_label)

	# --- Code wrapper (hidden by default) ---
	ui.code_wrapper = VBoxContainer.new()
	ui.code_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui.code_wrapper.visible = false
	ui.container.add_child(ui.code_wrapper)

	ui.code_editor = TextEdit.new()
	ui.code_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui.code_editor.custom_minimum_size = Vector2(0, 200)
	ui.code_editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	ui.code_editor.placeholder_text = "Generated GDScript will appear here..."
	ui.code_wrapper.add_child(ui.code_editor)

	# --- Streaming label (hidden, used to accumulate tokens) ---
	ui.streaming_label = RichTextLabel.new()
	ui.streaming_label.bbcode_enabled = false
	ui.streaming_label.visible = false
	ui.streaming_label.fit_content = true
	ui.container.add_child(ui.streaming_label)

	# --- Wire buttons ---
	ui.code_toggle_btn.pressed.connect(func() -> void:
		ui.code_wrapper.visible = not ui.code_wrapper.visible
		ui.code_toggle_btn.text = "Hide Code" if ui.code_wrapper.visible else "Show Code"
	)

	ui.recompile_btn.pressed.connect(func() -> void:
		var code: String = ui.code_editor.text.strip_edges()
		if code.is_empty():
			return
		_try_compile_and_preview_particle(code, ui)
	)

	ui.play_btn.pressed.connect(func() -> void:
		_play_particle_preview(ui)
	)

	return ui


func _on_particle_gen_completed(text: String, ui: ParticleAssetUI, asset_key: String) -> void:
	# Extract GDScript from the response (strip markdown fences)
	var raw_code := _extract_gdscript(text)

	# Run LLM sanitization pass if prompt is available
	if not _sanitize_prompt.is_empty() and LocalLLMService.is_model_loaded():
		_update_status("Sanitizing generated code...")
		var sanitized := await _run_sanitize_pass(raw_code)
		if not sanitized.is_empty():
			raw_code = sanitized

	_asset_results[asset_key] = raw_code

	# Put code into the editor (visible so user can review before compiling)
	ui.code_editor.text = raw_code
	ui.code_wrapper.visible = true
	ui.code_toggle_btn.text = "Hide Code"
	ui.recompile_btn.visible = true

	# Pre-validate: check for known bad patterns before attempting compilation
	var validation_errors := _pre_validate_gdscript(raw_code)
	if not validation_errors.is_empty():
		ui.error_label.text = "Code has issues (not compiled):\n%s\nFix the code and click Compile & Preview." % "\n".join(validation_errors)
		ui.error_label.visible = true
		ui.play_btn.disabled = true
	else:
		# Code looks safe to compile — try it
		_try_compile_and_preview_particle(raw_code, ui)

	_mark_row_selected(asset_key)
	_generation_finished("Particle effect generated - review code")


func _extract_gdscript(text: String) -> String:
	# Strip markdown code fences if the LLM wrapped it
	var result := text.strip_edges()

	# Handle ```gdscript\n...\n```
	if result.begins_with("```gdscript"):
		result = result.substr(len("```gdscript")).strip_edges()
	elif result.begins_with("```gd"):
		result = result.substr(len("```gd")).strip_edges()
	elif result.begins_with("```"):
		result = result.substr(3).strip_edges()

	if result.ends_with("```"):
		result = result.substr(0, result.length() - 3).strip_edges()

	return result


func _run_sanitize_pass(code: String) -> String:
	## Send code through the LLM sanitization prompt to fix Godot 3→4 issues.
	## Returns sanitized code, or empty string if sanitization fails.
	var result := await LocalLLMService.generate(code, {
		"system_prompt": _sanitize_prompt,
		"max_tokens": 1536,
		"temperature": 0.1
	})

	if result.get("success", false):
		var sanitized: String = result.get("text", "")
		sanitized = _extract_gdscript(sanitized)  # Strip fences if LLM added them
		if not sanitized.strip_edges().is_empty():
			return sanitized

	return ""


func _pre_validate_gdscript(code: String) -> Array[String]:
	## Quick static checks for known bad patterns that would crash script.reload()
	var errors: Array[String] = []

	if code.strip_edges().is_empty():
		errors.append("Code is empty")
		return errors

	# Check for remaining Godot 3.x connect syntax
	if code.contains('.connect("') and code.contains(', self,'):
		errors.append("Old Godot 3.x connect() syntax detected — use signal.connect(callable)")

	# Check for yield (Godot 3)
	if code.contains("yield("):
		errors.append("yield() is Godot 3.x syntax — use 'await' instead")

	# Check for old-style export
	var export_regex := RegEx.new()
	export_regex.compile("^export\\(")
	if export_regex.search(code) != null:
		errors.append("export() is Godot 3.x syntax — use @export")

	# Check for missing extends
	var has_extends := false
	for line in code.split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("extends "):
			has_extends = true
			break
	if not has_extends:
		errors.append("Missing 'extends' declaration")

	return errors


func _try_compile_and_preview_particle(source_code: String, ui: ParticleAssetUI) -> void:
	ui.error_label.visible = false
	ui.error_label.text = ""
	_cleanup_preview()

	# Final pre-validation before calling reload() (which can trigger editor debugger)
	var pre_errors := _pre_validate_gdscript(source_code)
	if not pre_errors.is_empty():
		ui.error_label.text = "Cannot compile — fix these issues first:\n%s" % "\n".join(pre_errors)
		ui.error_label.visible = true
		ui.code_wrapper.visible = true
		ui.code_toggle_btn.text = "Hide Code"
		ui.play_btn.disabled = true
		return

	# Compile the GDScript
	var script := GDScript.new()
	script.source_code = source_code
	var err := script.reload()

	if err != OK:
		ui.error_label.text = "Compilation failed (error %d). Edit the code and click Compile & Preview." % err
		ui.error_label.visible = true
		ui.code_wrapper.visible = true
		ui.code_toggle_btn.text = "Hide Code"
		ui.play_btn.disabled = true
		return

	# Instantiate the scene into the SubViewport
	var instance: Node = script.new()
	if instance == null:
		ui.error_label.text = "Failed to instantiate script."
		ui.error_label.visible = true
		ui.play_btn.disabled = true
		return

	ui.preview_viewport.add_child(instance)
	_preview_instance = instance
	ui.play_btn.disabled = false
	ui.error_label.visible = false


func _play_particle_preview(ui: ParticleAssetUI) -> void:
	if _preview_instance == null or not is_instance_valid(_preview_instance):
		ui.error_label.text = "No particle instance to play."
		ui.error_label.visible = true
		return

	# Call play_at if available
	if _preview_instance.has_method("play_at"):
		# Center in the viewport
		var vp_size := ui.preview_viewport.size
		if _preview_instance is Node2D:
			_preview_instance.call("play_at", Vector2(vp_size.x / 2, vp_size.y / 2))
		elif _preview_instance is Node3D:
			_preview_instance.call("play_at", Vector3.ZERO)
		else:
			_preview_instance.call("play_at", Vector2(vp_size.x / 2, vp_size.y / 2))
	else:
		ui.error_label.text = "Script has no play_at() method."
		ui.error_label.visible = true
