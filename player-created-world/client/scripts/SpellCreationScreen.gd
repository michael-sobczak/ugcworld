## Spell Creation Screen - Graph-based LLM spell pipeline
## Autoloads: LocalLLMService
##
## Each pipeline step (description, manifest, particle, shape, sanitize,
## human review, compile & save) is a node in a directed graph built with
## the Custom Graph Editor addon.
## Edges represent data flow: the output of one step feeds as input to the next.
## All LLM calls go through _llm_request / _llm_generate which use
## generate_streaming on a C++ worker thread (never blocks the UI).
extends CanvasLayer

const SpellGraphNode := preload("res://client/scripts/spell_graph/SpellGraphNode.gd")

const DESCRIPTION_PROMPT_PATH := "res://client/prompts/generate_spell_description.md"
const ASSET_PROMPT_PATH := "res://client/prompts/generate_spell_asset_manifest.md"
const PARTICLE_PROMPT_PATH := "res://client/prompts/generate_particle_effect.md"
const SHAPE_PROMPT_PATH := "res://client/prompts/generate_simple_shapes.md"

@onready var close_button: Button = $Panel/VBox/Header/CloseButton
@onready var input_field: TextEdit = $Panel/VBox/InputContainer/InputField
@onready var send_button: Button = $Panel/VBox/InputContainer/SendButton
@onready var status_label: Label = $Panel/VBox/StatusBar/StatusLabel
@onready var graph_editor: CGEGraphEditor = $Panel/VBox/GraphContainer/SpellGraph

var _prompts: Dictionary = {}
var _is_generating: bool = false
var _current_handle: Object = null
var _loaded_model_id: String = ""

## Maps graph node IDs to their SpellGraphNode data for quick access
var _node_data: Dictionary = {}  # node_id -> SpellGraphNode

## Maps Human Review node IDs to their downstream chain { "validate": id, "compile": id }
var _review_chain: Dictionary = {}  # review_node_id -> { "validate": int, "compile": int }

## Tracks pending popup to avoid opening during drags
var _pending_popup_node_id: int = -1

## Currently open popup overlay (if any)
var _active_popup: Control = null


func _ready() -> void:
	send_button.pressed.connect(_on_send_pressed)
	close_button.pressed.connect(_on_close_pressed)
	input_field.gui_input.connect(_on_input_gui_input)

	visible = false
	_prompts = {
		"description": _load_prompt(DESCRIPTION_PROMPT_PATH),
		"assets": _load_prompt(ASSET_PROMPT_PATH),
		"particle": _load_prompt(PARTICLE_PROMPT_PATH),
		"shape": _load_prompt(SHAPE_PROMPT_PATH),
	}
	_update_status("")
	_configure_graph_editor()

	# Connect to graph editor selection for node click popups
	graph_editor.graph_element_selected.connect(_on_graph_element_clicked)


func show_screen(model_id: String) -> void:
	_loaded_model_id = model_id
	visible = true
	_clear_graph()
	input_field.text = ""
	input_field.grab_focus()
	_update_status("Ready")
	_set_camera_controls(false)


func hide_screen() -> void:
	_close_active_popup()
	visible = false
	_set_camera_controls(true)


func _on_close_pressed() -> void:
	hide_screen()


# ============================================================================
# Input Handling
# ============================================================================

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if _active_popup != null:
				_close_active_popup()
			else:
				hide_screen()
			get_viewport().set_input_as_handled()


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
	if not _ensure_llm_ready():
		return

	_begin_generating("Running spell pipeline...")
	_clear_graph()
	_run_spell_pipeline(prompt)


# ============================================================================
# Graph Editor Configuration
# ============================================================================

## Hide the toolbar (File / Edit / Add Node menu) and other chrome that is
## not needed for the spell creation pipeline display.
func _configure_graph_editor() -> void:
	# Use the graph editor's own internal references (set via @onready before
	# our _ready runs, since children are readied first).
	if graph_editor._toolbar != null:
		graph_editor._toolbar.visible = false
	if graph_editor._inspector_panel != null:
		graph_editor._inspector_panel.visible = false
	if graph_editor._h_scroll_bar != null:
		graph_editor._h_scroll_bar.visible = false
	if graph_editor._v_scroll_bar != null:
		graph_editor._v_scroll_bar.visible = false

	# Left-click on empty space pans the view instead of drag-box selecting
	graph_editor.left_click_pans = true


# ============================================================================
# Camera Control Toggle
# ============================================================================

## Enable or disable the 3D camera controls in the ClientController.
func _set_camera_controls(enabled: bool) -> void:
	var controller := get_node_or_null("../ClientController")
	if controller and "camera_controls_enabled" in controller:
		controller.camera_controls_enabled = enabled


# ============================================================================
# Uniform LLM Interface (non-blocking, worker thread)
# ============================================================================

func _llm_request(prompt: String, system_prompt: String, opts: Dictionary = {}) -> String:
	var handle = LocalLLMService.generate_streaming({
		"prompt": prompt,
		"system_prompt": system_prompt,
		"max_tokens": opts.get("max_tokens", 1024),
		"temperature": opts.get("temperature", 0.7),
	})
	if handle == null:
		return ""
	_current_handle = handle
	var result := await _await_handle(handle)
	_current_handle = null
	return result


func _llm_generate(prompt: String, system_prompt: String, opts: Dictionary = {}) -> String:
	return await _llm_request(prompt, system_prompt, opts)


func _await_handle(handle: Object) -> String:
	if handle == null:
		return ""
	while handle.get_status() == 0 or handle.get_status() == 1:
		await get_tree().process_frame
	if handle.get_status() == 2:
		return handle.get_full_text()
	return ""


# ============================================================================
# Helpers
# ============================================================================

func _ensure_llm_ready() -> bool:
	if not LocalLLMService.is_extension_available():
		_update_status("LLM extension not available")
		return false
	if not LocalLLMService.is_model_loaded():
		_update_status("No model loaded. Press S to select a model.")
		return false
	return true


func _begin_generating(msg: String) -> void:
	_is_generating = true
	send_button.disabled = true
	_update_status(msg)


func _finish_generating(msg: String) -> void:
	_is_generating = false
	send_button.disabled = false
	_update_status(msg)


func _update_status(message: String) -> void:
	var model_id := LocalLLMService.get_loaded_model_id()
	var s := "Model: %s" % (model_id if not model_id.is_empty() else "None")
	if not message.is_empty():
		s += " | " + message
	status_label.text = s


func _load_prompt(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _clear_graph() -> void:
	graph_editor.graph.clear_all()
	_node_data.clear()
	_review_chain.clear()


# ============================================================================
# Graph Node Helpers
# ============================================================================

func _add_graph_node(step_type: int, label: String, prompt_key: String, pos: Vector2) -> int:
	var node: CGEGraphNode = graph_editor.graph.create_node()
	var node_id: int = node.id

	# Set SpellGraphNode-specific data
	var spell_node: SpellGraphNode = node as SpellGraphNode
	spell_node.step_type = step_type
	spell_node.step_label = label
	spell_node.prompt_key = prompt_key
	spell_node.status = "pending"

	_node_data[node_id] = spell_node

	# Position the UI node
	var ui_node := graph_editor.get_graph_node(node_id)
	if ui_node:
		ui_node.position = pos
		ui_node.refresh()

	return node_id


func _add_graph_edge(from_id: int, to_id: int) -> void:
	graph_editor.graph.create_link(from_id, to_id)


func _set_node_status(node_id: int, status: String, result: String = "", error: String = "") -> void:
	var spell_node: SpellGraphNode = _node_data.get(node_id) as SpellGraphNode
	if spell_node == null:
		return
	spell_node.status = status
	if not result.is_empty():
		spell_node.result_text = result
	# Clear stale error when transitioning to a non-error status
	if status != "error":
		spell_node.error_text = ""
	if not error.is_empty():
		spell_node.error_text = error

	var ui_node := graph_editor.get_graph_node(node_id)
	if ui_node and ui_node.has_method("refresh"):
		ui_node.refresh()


func _set_node_input(node_id: int, input: String) -> void:
	var spell_node: SpellGraphNode = _node_data.get(node_id) as SpellGraphNode
	if spell_node:
		spell_node.input_text = input


func _get_node_result(node_id: int) -> String:
	var spell_node: SpellGraphNode = _node_data.get(node_id) as SpellGraphNode
	if spell_node == null:
		return ""
	return spell_node.result_text


# ============================================================================
# Graph Centering & Auto-Zoom
# ============================================================================

## Reposition all graph nodes so the pipeline is centred in the view.
## Automatically adjusts zoom so the full graph fits with padding.
##
## This bypasses the graph editor's own set_zoom() and _center_scrollbars()
## because those methods adjust scroll values based on mouse position and
## use page/2 (= 40% of size) rather than size/2 (true centre).  For a
## read-only pipeline display we need pixel-perfect centering.
func _center_graph_nodes() -> void:
	if _node_data.is_empty():
		return

	# 1. Compute bounding box of all nodes
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)

	for node_id in _node_data:
		var ui_node := graph_editor.get_graph_node(node_id)
		if ui_node == null:
			continue
		min_pos.x = min(min_pos.x, ui_node.position.x)
		min_pos.y = min(min_pos.y, ui_node.position.y)
		max_pos.x = max(max_pos.x, ui_node.position.x + ui_node.size.x)
		max_pos.y = max(max_pos.y, ui_node.position.y + ui_node.size.y)

	var graph_center := (min_pos + max_pos) / 2.0
	var graph_size := max_pos - min_pos

	# 2. Shift every node so the graph centroid sits at world origin (0, 0)
	for node_id in _node_data:
		var ui_node := graph_editor.get_graph_node(node_id)
		if ui_node:
			ui_node.position -= graph_center

	# 3. Refresh all links after repositioning
	for node_id in _node_data:
		var ui_node := graph_editor.get_graph_node(node_id)
		if ui_node:
			ui_node.moved.emit()

	# 4. Compute zoom so the full graph fits inside the visible area
	var view_size := graph_editor.size
	if view_size.x <= 0 or view_size.y <= 0:
		return  # Editor not laid out yet

	var target_zoom := 1.0
	if graph_size.x > 0 and graph_size.y > 0:
		var padding := 40.0
		var available := view_size - Vector2(padding, padding)
		var zoom_x := available.x / graph_size.x
		var zoom_y := available.y / graph_size.y
		target_zoom = minf(minf(zoom_x, zoom_y), 1.0)
		target_zoom = clamp(target_zoom, graph_editor.min_zoom, graph_editor.max_zoom)

	# 5. Apply zoom directly — we bypass set_zoom() because it adjusts
	#    scrollbars relative to the current mouse position, which shifts
	#    the view unpredictably when called programmatically.
	graph_editor.zoom = target_zoom
	graph_editor._grid.zoom = target_zoom
	graph_editor._content.scale = Vector2(target_zoom, target_zoom)

	# 6. Position the view so the world origin (graph centroid) is at the
	#    exact centre of the editor.  The content's position in screen space
	#    equals -scroll_value, so scroll = -size/2 ⟹ content_pos = size/2.
	graph_editor._update_scrollbar_pages()
	if graph_editor._h_scroll_bar:
		graph_editor._h_scroll_bar.value = -view_size.x / 2.0
	if graph_editor._v_scroll_bar:
		graph_editor._v_scroll_bar.value = -view_size.y / 2.0

	graph_editor.queue_redraw()


# ============================================================================
# Node Click → Popup System
# ============================================================================

## Called when a graph element is selected (clicked).
## After a short delay, if the node wasn't dragged, show a detail popup.
func _on_graph_element_clicked(element) -> void:
	if _active_popup != null:
		return
	if not element is CGEGraphNodeUI:
		_pending_popup_node_id = -1
		return

	var ui_node := element as CGEGraphNodeUI
	var spell_node := ui_node.graph_element as SpellGraphNode
	if spell_node == null:
		_pending_popup_node_id = -1
		return

	# Allow clicking nodes that have finished or errored even while pipeline runs.
	# Nodes still pending/running have nothing to show yet.
	if spell_node.status == "pending" or spell_node.status == "running":
		return

	var node_id := spell_node.id
	var start_pos := ui_node.position
	_pending_popup_node_id = node_id

	# Brief delay to distinguish click from drag
	await get_tree().create_timer(0.25).timeout

	# Verify it was a click, not a drag, and nothing else happened
	if _pending_popup_node_id != node_id:
		return
	if _active_popup != null:
		return
	var current_ui := graph_editor.get_graph_node(node_id)
	if current_ui == null:
		return
	if current_ui.position.distance_to(start_pos) > 3.0:
		return  # Was dragged

	_pending_popup_node_id = -1
	_show_popup_for_node(spell_node)


## Route to the appropriate popup based on step type.
func _show_popup_for_node(spell_node: SpellGraphNode) -> void:
	match spell_node.step_type:
		SpellGraphNode.StepType.HUMAN_REVIEW:
			_show_human_review_popup(spell_node)
		SpellGraphNode.StepType.COMPILE_SAVE:
			_show_compile_preview_popup(spell_node)
		SpellGraphNode.StepType.VALIDATE:
			_show_node_detail_popup(spell_node)  # Shows input/output/error
		_:
			_show_node_detail_popup(spell_node)


# ============================================================================
# Popup Helpers
# ============================================================================

## Create a centred popup overlay and return the VBox for content.
func _open_popup(title_text: String, popup_size: Vector2 = Vector2(550, 400)) -> VBoxContainer:
	_close_active_popup()

	# Semi-transparent overlay to block interaction with the graph.
	# z_index must be high to render above the graph editor's internal nodes.
	var overlay := ColorRect.new()
	overlay.name = "PopupOverlay"
	overlay.color = Color(0, 0, 0, 0.4)
	overlay.anchor_right = 1.0
	overlay.anchor_bottom = 1.0
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.z_index = 100

	# Centring wrapper
	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)

	# Panel
	var panel := PanelContainer.new()
	panel.custom_minimum_size = popup_size
	center.add_child(panel)

	# Margin
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	# VBox
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Title row
	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	var title_lbl := Label.new()
	title_lbl.text = title_text
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_lbl)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.pressed.connect(_close_active_popup)
	title_row.add_child(close_btn)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	add_child(overlay)
	_active_popup = overlay

	return vbox


func _close_active_popup() -> void:
	if _active_popup != null and is_instance_valid(_active_popup):
		_active_popup.queue_free()
	_active_popup = null


# ============================================================================
# Node Detail Popup (generic – shows input & output with copy buttons)
# ============================================================================

func _show_node_detail_popup(spell_node: SpellGraphNode) -> void:
	var vbox := _open_popup(spell_node.step_label)

	# --- Input section ---
	if not spell_node.input_text.is_empty():
		var input_lbl := Label.new()
		input_lbl.text = "Input:"
		input_lbl.add_theme_font_size_override("font_size", 12)
		input_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		vbox.add_child(input_lbl)

		var input_edit := TextEdit.new()
		input_edit.text = spell_node.input_text
		input_edit.editable = false
		input_edit.custom_minimum_size.y = 80
		input_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
		input_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		vbox.add_child(input_edit)

		var copy_in_btn := Button.new()
		copy_in_btn.text = "Copy Input"
		copy_in_btn.pressed.connect(func(): DisplayServer.clipboard_set(spell_node.input_text))
		vbox.add_child(copy_in_btn)

	# --- Output section ---
	if not spell_node.result_text.is_empty():
		var output_lbl := Label.new()
		output_lbl.text = "Output:"
		output_lbl.add_theme_font_size_override("font_size", 12)
		output_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		vbox.add_child(output_lbl)

		var output_edit := TextEdit.new()
		output_edit.text = spell_node.result_text
		output_edit.editable = false
		output_edit.custom_minimum_size.y = 80
		output_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
		output_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		vbox.add_child(output_edit)

		var copy_out_btn := Button.new()
		copy_out_btn.text = "Copy Output"
		copy_out_btn.pressed.connect(func(): DisplayServer.clipboard_set(spell_node.result_text))
		vbox.add_child(copy_out_btn)

	# --- Error section ---
	if not spell_node.error_text.is_empty():
		var err_lbl := Label.new()
		err_lbl.text = "Error: " + spell_node.error_text
		err_lbl.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
		vbox.add_child(err_lbl)


# ============================================================================
# Human Review Popup (editable – allows changing code before compile)
# ============================================================================

func _show_human_review_popup(spell_node: SpellGraphNode) -> void:
	var node_id := spell_node.id
	var vbox := _open_popup("Human Review – " + spell_node.step_label, Vector2(650, 500))

	var info_lbl := Label.new()
	info_lbl.text = "Review the generated code below. Edit if needed, then press Accept."
	info_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	info_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(info_lbl)

	var code_edit := TextEdit.new()
	code_edit.text = spell_node.result_text
	code_edit.custom_minimum_size.y = 300
	code_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(code_edit)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var accept_btn := Button.new()
	accept_btn.text = "Accept & Continue"
	accept_btn.pressed.connect(func():
		_on_human_review_confirmed(node_id, code_edit.text)
	)
	btn_row.add_child(accept_btn)

	var regen_btn := Button.new()
	regen_btn.text = "Regenerate"
	regen_btn.tooltip_text = "Re-run the LLM to generate fresh code for this asset"
	regen_btn.pressed.connect(func():
		_on_human_review_regenerate(node_id)
	)
	btn_row.add_child(regen_btn)

	var copy_btn := Button.new()
	copy_btn.text = "Copy Code"
	copy_btn.pressed.connect(func(): DisplayServer.clipboard_set(code_edit.text))
	btn_row.add_child(copy_btn)


## Called when the user clicks "Regenerate" in the Human Review popup.
## Re-runs the upstream LLM generation step and feeds the new code through
## the full review → validate → compile chain.
func _on_human_review_regenerate(review_node_id: int) -> void:
	_close_active_popup()

	var chain: Dictionary = _review_chain.get(review_node_id, {})
	var gen_id: int = chain.get("gen", -1)
	var validate_id: int = chain.get("validate", -1)
	var compile_id: int = chain.get("compile", -1)
	var prompt_key: String = chain.get("prompt_key", "")

	if gen_id < 0 or prompt_key.is_empty():
		_update_status("Cannot regenerate – missing upstream node info")
		return

	if not _ensure_llm_ready():
		return

	# Get the original description that was used as input to the gen node
	var gen_node := _node_data.get(gen_id) as SpellGraphNode
	if gen_node == null or gen_node.input_text.is_empty():
		_update_status("Cannot regenerate – no input description found")
		return

	var description: String = gen_node.input_text

	# Reset the entire chain to "running" / "pending" for visual feedback
	_set_node_status(gen_id, "running")
	_set_node_status(review_node_id, "pending")
	if validate_id >= 0:
		_set_node_status(validate_id, "pending")
	if compile_id >= 0:
		_set_node_status(compile_id, "pending")
	_update_status("Regenerating %s..." % prompt_key)

	# Re-run the LLM generation
	var raw_code := await _llm_request(description, _prompts.get(prompt_key, ""))
	if raw_code.is_empty():
		_set_node_status(gen_id, "error", "", "Regeneration failed")
		_update_status("Regeneration failed")
		return

	var code := _extract_gdscript(raw_code)
	_set_node_status(gen_id, "done", code)

	# Feed through review (auto-accept the new code)
	_set_node_input(review_node_id, code)
	_set_node_status(review_node_id, "done", code)

	# Validate
	if validate_id >= 0:
		_set_node_input(validate_id, code)
		_set_node_status(validate_id, "running")
		_update_status("Validating regenerated code...")
		var vresult := _validate_code(code)
		if vresult["valid"]:
			_set_node_status(validate_id, "done", code)
			if compile_id >= 0:
				_set_node_input(compile_id, code)
				_set_node_status(compile_id, "done", code)
			_update_status("Regeneration complete – click Review node to inspect")
		else:
			_set_node_status(validate_id, "error", "", vresult["error"])
			if compile_id >= 0:
				_set_node_status(compile_id, "error", "", "Upstream validation failed")
			_update_status("Regenerated code failed validation – edit in Human Review to fix")


## Called when the user confirms edits in the Human Review popup.
## Updates the review node's result and re-runs validation → compile.
func _on_human_review_confirmed(node_id: int, new_code: String) -> void:
	var spell_node := _node_data.get(node_id) as SpellGraphNode
	if spell_node == null:
		_close_active_popup()
		return

	spell_node.result_text = new_code
	var ui_node := graph_editor.get_graph_node(node_id)
	if ui_node and ui_node.has_method("refresh"):
		ui_node.refresh()

	_close_active_popup()

	# Re-run validation → compile chain
	var chain: Dictionary = _review_chain.get(node_id, {})
	var validate_id: int = chain.get("validate", -1)
	var compile_id: int = chain.get("compile", -1)

	if validate_id >= 0:
		# Show visual feedback while re-validating
		_set_node_input(validate_id, new_code)
		_set_node_status(validate_id, "running")
		if compile_id >= 0:
			_set_node_status(compile_id, "pending")
		_update_status("Re-validating edited code...")

		var result := _validate_code(new_code)
		if result["valid"]:
			_set_node_status(validate_id, "done", new_code)
			if compile_id >= 0:
				_set_node_input(compile_id, new_code)
				_set_node_status(compile_id, "done", new_code)
			_update_status("Re-validation passed – click any node to inspect")
		else:
			_set_node_status(validate_id, "error", "", result["error"])
			if compile_id >= 0:
				_set_node_status(compile_id, "error", "", "Upstream validation failed")
			_update_status("Re-validation failed – edit in Human Review to fix")


# ============================================================================
# Compile & Save Preview Popup
# ============================================================================

func _show_compile_preview_popup(spell_node: SpellGraphNode) -> void:
	var vbox := _open_popup("Compile & Save – " + spell_node.step_label, Vector2(700, 620))

	var preview_ok := false

	# Only attempt live preview if the node is in "done" state (passed validation)
	if spell_node.status == "done" and not spell_node.result_text.is_empty():
		var preview_label := Label.new()
		preview_label.text = "Preview:"
		preview_label.add_theme_font_size_override("font_size", 12)
		preview_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		vbox.add_child(preview_label)

		var preview_container := SubViewportContainer.new()
		preview_container.custom_minimum_size = Vector2(0, 280)
		preview_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
		preview_container.stretch = true
		vbox.add_child(preview_container)

		var viewport := SubViewport.new()
		viewport.size = Vector2i(660, 280)
		viewport.transparent_bg = false
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		preview_container.add_child(viewport)

		preview_container.set_meta("effect_code", spell_node.result_text)
		preview_container.set_meta("viewport", viewport)

		preview_ok = _try_spawn_particle_preview(viewport, spell_node.result_text)

		if not preview_ok:
			var err_lbl := Label.new()
			err_lbl.text = "Preview unavailable (runtime error in _ready)"
			err_lbl.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))
			err_lbl.add_theme_font_size_override("font_size", 11)
			vbox.add_child(err_lbl)
	else:
		# Node is in error state – show the error
		if not spell_node.error_text.is_empty():
			var err_lbl := Label.new()
			err_lbl.text = "Validation failed: " + spell_node.error_text
			err_lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			err_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			vbox.add_child(err_lbl)

	# --- Code section ---
	var code_text: String = spell_node.result_text if not spell_node.result_text.is_empty() else spell_node.input_text
	if not code_text.is_empty():
		var code_edit := TextEdit.new()
		code_edit.text = code_text
		code_edit.editable = false
		code_edit.custom_minimum_size.y = 140
		code_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
		vbox.add_child(code_edit)

	# --- Buttons ---
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	if not code_text.is_empty():
		var copy_btn := Button.new()
		copy_btn.text = "Copy Code"
		copy_btn.pressed.connect(func(): DisplayServer.clipboard_set(code_text))
		btn_row.add_child(copy_btn)

	if preview_ok:
		var pc := vbox.get_child(2) as SubViewportContainer  # preview_container
		var replay_btn := Button.new()
		replay_btn.text = "Replay Effect"
		replay_btn.pressed.connect(func():
			_replay_particle_preview(pc)
		)
		btn_row.add_child(replay_btn)


# ============================================================================
# Code Validation (compile-check without entering the scene tree)
# ============================================================================

## Attempt to compile the GDScript code and perform basic sanity checks.
## Returns { "valid": bool, "error": String }.
## This does NOT execute _ready() – it only verifies the script parses,
## instantiates, and has the expected type / API.
static func _validate_code(code: String) -> Dictionary:
	if code.strip_edges().is_empty():
		return {"valid": false, "error": "Empty code"}

	if _code_has_external_refs(code):
		return {"valid": false, "error": "Code references external files (load/preload not allowed)"}

	# 1. Compile
	var script := GDScript.new()
	script.source_code = code
	var err := script.reload()
	if err != OK:
		return {"valid": false, "error": "GDScript compile error (code %d) – invalid properties or syntax" % err}

	# 2. Instantiate (does NOT call _ready; the node is never added to a tree)
	var instance = script.new()
	if instance == null:
		return {"valid": false, "error": "Script instantiation failed"}

	# 3. Type check
	var is_node := instance is Node
	if not is_node:
		return {"valid": false, "error": "Script must extend a Node type (Node2D or Node3D)"}

	var node: Node = instance as Node
	var is_correct_type := node is Node2D or node is Node3D
	var has_play_at := node.has_method("play_at")

	# 4. Clean up (never entered the tree, so free() is safe)
	node.free()

	if not is_correct_type:
		return {"valid": false, "error": "Script must extend Node2D or Node3D"}
	if not has_play_at:
		return {"valid": false, "error": "Missing required play_at() method"}

	return {"valid": true, "error": ""}


# ============================================================================
# Particle Effect Preview (SubViewport)
# ============================================================================

## Try to dynamically load the particle GDScript, instantiate it inside the
## given SubViewport, and trigger play_at().  Returns true on success.
## The code should already have passed _validate_code() before reaching here.
func _try_spawn_particle_preview(viewport: SubViewport, code: String) -> bool:
	# Run a full validation first — this catches parse errors safely
	# before we ever touch the scene tree.
	var check := _validate_code(code)
	if not check["valid"]:
		push_warning("[SpellPreview] Pre-check failed: %s" % check["error"])
		return false

	# Safe to compile & instantiate (validation already proved this works)
	var script := GDScript.new()
	script.source_code = code
	var err := script.reload()
	if err != OK:
		return false  # Should not happen after validation

	var instance = script.new()
	if instance == null:
		return false

	if instance is Node2D:
		# --- 2D preview ---
		var bg := ColorRect.new()
		bg.name = "PreviewBG"
		bg.color = Color(0.08, 0.08, 0.12, 1.0)
		bg.size = Vector2(viewport.size)
		viewport.add_child(bg)
		viewport.add_child(instance)

		# Trigger the effect after _ready() has run
		var center := Vector2(viewport.size) / 2.0
		get_tree().create_timer(0.1).timeout.connect(func():
			if is_instance_valid(instance) and instance.has_method("play_at"):
				instance.play_at(center)
		)
		return true

	elif instance is Node3D:
		# --- 3D preview ---
		var cam := Camera3D.new()
		cam.position = Vector3(0, 1.5, 4)
		cam.look_at(Vector3.ZERO)
		viewport.add_child(cam)

		var env := WorldEnvironment.new()
		var environment := Environment.new()
		environment.background_mode = Environment.BG_COLOR
		environment.background_color = Color(0.08, 0.08, 0.12)
		environment.ambient_light_color = Color(0.4, 0.4, 0.5)
		environment.ambient_light_energy = 0.6
		env.environment = environment
		viewport.add_child(env)

		var light := DirectionalLight3D.new()
		light.rotation_degrees = Vector3(-45, -45, 0)
		viewport.add_child(light)

		viewport.add_child(instance)

		get_tree().create_timer(0.1).timeout.connect(func():
			if is_instance_valid(instance) and instance.has_method("play_at"):
				instance.play_at(Vector3.ZERO)
		)
		return true

	else:
		push_warning("[SpellPreview] Script instance is neither Node2D nor Node3D")
		if instance is Node:
			instance.queue_free()
		return false


## Remove the old particle instance and spawn a fresh one for replay.
func _replay_particle_preview(container: SubViewportContainer) -> void:
	var code: String = container.get_meta("effect_code", "")
	var viewport: SubViewport = container.get_meta("viewport", null) as SubViewport
	if code.is_empty() or viewport == null:
		return

	# Remove everything except the background ColorRect
	for child in viewport.get_children():
		if child.name == "PreviewBG":
			continue
		# Keep cameras, lights, environments for 3D
		if child is Camera3D or child is DirectionalLight3D or child is WorldEnvironment:
			continue
		child.queue_free()

	# Wait a frame for cleanup
	await get_tree().process_frame

	# Re-compile & spawn
	var script := GDScript.new()
	script.source_code = code
	if script.reload() != OK:
		return

	var instance = script.new()
	if instance == null:
		return

	viewport.add_child(instance)

	get_tree().create_timer(0.1).timeout.connect(func():
		if not is_instance_valid(instance):
			return
		if instance is Node2D and instance.has_method("play_at"):
			instance.play_at(Vector2(viewport.size) / 2.0)
		elif instance is Node3D and instance.has_method("play_at"):
			instance.play_at(Vector3.ZERO)
	)


## Returns true if the code contains load/preload or file path references
## that would crash when running in a sandboxed preview.
static func _code_has_external_refs(code: String) -> bool:
	# Quick regex-free check for common patterns
	for pattern in ["load(", "preload(", 'res://', 'user://']:
		if code.find(pattern) >= 0:
			return true
	return false


# ============================================================================
# Spell Pipeline as Graph
# ============================================================================

func _run_spell_pipeline(user_prompt: String) -> void:
	## Layout constants – compact spacing for 7 columns.
	## Columns: Input(0) Desc(1) Manifest(2) Gen(3) Review(4) Validate(5) Compile(6)
	const COL_W := 160.0
	const ROW_H := 65.0

	# =====================================================================
	# PHASE 1 — Build the first three nodes (we don't know row count yet)
	# =====================================================================
	var input_id := _add_graph_node(
		SpellGraphNode.StepType.USER_INPUT, "User Prompt", "",
		Vector2(0, 0)
	)
	_set_node_status(input_id, "done", user_prompt)

	var desc_id := _add_graph_node(
		SpellGraphNode.StepType.DESCRIPTION, "Description", "description",
		Vector2(COL_W, 0)
	)
	_add_graph_edge(input_id, desc_id)

	var manifest_id := _add_graph_node(
		SpellGraphNode.StepType.ASSET_MANIFEST, "Manifest", "assets",
		Vector2(COL_W * 2, 0)
	)
	_add_graph_edge(desc_id, manifest_id)

	_center_graph_nodes()

	# --- Step 1: Generate description ---
	_set_node_input(desc_id, user_prompt)
	_set_node_status(desc_id, "running")
	var description := await _llm_request(
		user_prompt,
		_prompts.get("description", "")
	)
	if description.is_empty():
		_set_node_status(desc_id, "error", "", "Generation failed")
		_finish_generating("Description generation failed")
		return
	_set_node_status(desc_id, "done", description)

	# --- Step 2: Generate asset manifest ---
	_set_node_input(manifest_id, description)
	_set_node_status(manifest_id, "running")
	var manifest_text := await _llm_request(
		description,
		_prompts.get("assets", "")
	)
	if manifest_text.is_empty():
		_set_node_status(manifest_id, "error", "", "Generation failed")
		_finish_generating("Manifest generation failed")
		return
	_set_node_status(manifest_id, "done", manifest_text)

	# --- Step 3: Parse manifest ---
	var entries := _parse_manifest(manifest_text)
	if entries.is_empty():
		_set_node_status(manifest_id, "error", manifest_text, "Failed to parse manifest")
		_finish_generating("Manifest parse failed")
		return

	# Separate shapes from particle entries
	var shape_descriptions: PackedStringArray = []
	var particle_entries: Array[Dictionary] = []

	for entry in entries:
		if entry["type"] == "shape":
			shape_descriptions.append(entry["description"])
		else:
			particle_entries.append(entry)

	# =====================================================================
	# PHASE 2 — Create ALL downstream nodes (including Validate) at their
	#           final positions, THEN centre the whole graph once.
	# =====================================================================

	var total_rows: int = particle_entries.size()
	if not shape_descriptions.is_empty():
		total_rows += 1
	var first_row_y: float = (total_rows - 1) * ROW_H / 2.0

	# Re-position the initial three nodes to the centre row
	var input_ui := graph_editor.get_graph_node(input_id)
	if input_ui:
		input_ui.position = Vector2(0, first_row_y)
	var desc_ui := graph_editor.get_graph_node(desc_id)
	if desc_ui:
		desc_ui.position = Vector2(COL_W, first_row_y)
	var manifest_ui := graph_editor.get_graph_node(manifest_id)
	if manifest_ui:
		manifest_ui.position = Vector2(COL_W * 2, first_row_y)

	## Track node IDs per row for generation phase.
	var particle_rows: Array[Dictionary] = []
	var row := 0

	for i in range(particle_entries.size()):
		var y: float = row * ROW_H

		var gen_id := _add_graph_node(
			SpellGraphNode.StepType.PARTICLE,
			"Particle %d" % (i + 1), "particle",
			Vector2(COL_W * 3, y)
		)
		_add_graph_edge(manifest_id, gen_id)

		var review_id := _add_graph_node(
			SpellGraphNode.StepType.HUMAN_REVIEW,
			"Review P%d" % (i + 1), "",
			Vector2(COL_W * 4, y)
		)
		_add_graph_edge(gen_id, review_id)

		var validate_id := _add_graph_node(
			SpellGraphNode.StepType.VALIDATE,
			"Validate P%d" % (i + 1), "",
			Vector2(COL_W * 5, y)
		)
		_add_graph_edge(review_id, validate_id)

		var compile_id := _add_graph_node(
			SpellGraphNode.StepType.COMPILE_SAVE,
			"Compile P%d" % (i + 1), "",
			Vector2(COL_W * 6, y)
		)
		_add_graph_edge(validate_id, compile_id)
		_review_chain[review_id] = {"gen": gen_id, "validate": validate_id, "compile": compile_id, "prompt_key": "particle"}

		particle_rows.append({
			"gen": gen_id,
			"review": review_id, "validate": validate_id, "compile": compile_id,
			"description": particle_entries[i]["description"],
		})
		row += 1

	# Shape row (if any)
	var shape_ids: Dictionary = {}
	if not shape_descriptions.is_empty():
		var y: float = row * ROW_H
		var combined := ""
		for sd in shape_descriptions:
			combined += "- %s\n" % sd
		combined = combined.strip_edges()

		var shape_gen_id := _add_graph_node(
			SpellGraphNode.StepType.SHAPE,
			"Shapes (%d)" % shape_descriptions.size(), "shape",
			Vector2(COL_W * 3, y)
		)
		_add_graph_edge(manifest_id, shape_gen_id)

		var shape_review_id := _add_graph_node(
			SpellGraphNode.StepType.HUMAN_REVIEW,
			"Review S", "",
			Vector2(COL_W * 4, y)
		)
		_add_graph_edge(shape_gen_id, shape_review_id)

		var shape_validate_id := _add_graph_node(
			SpellGraphNode.StepType.VALIDATE,
			"Validate S", "",
			Vector2(COL_W * 5, y)
		)
		_add_graph_edge(shape_review_id, shape_validate_id)

		var shape_compile_id := _add_graph_node(
			SpellGraphNode.StepType.COMPILE_SAVE,
			"Compile S", "",
			Vector2(COL_W * 6, y)
		)
		_add_graph_edge(shape_validate_id, shape_compile_id)
		_review_chain[shape_review_id] = {"gen": shape_gen_id, "validate": shape_validate_id, "compile": shape_compile_id, "prompt_key": "shape"}

		shape_ids = {
			"gen": shape_gen_id,
			"review": shape_review_id, "validate": shape_validate_id,
			"compile": shape_compile_id, "combined": combined,
		}

	# One single centre pass for the complete graph
	_center_graph_nodes()

	# =====================================================================
	# PHASE 3 — Run generation sequentially.  Each chain now includes a
	#           validation step that compile-checks the code before the
	#           Compile & Save node is marked done.
	# =====================================================================

	for pr in particle_rows:
		var gen_id: int = pr["gen"]
		var review_id: int = pr["review"]
		var validate_id: int = pr["validate"]
		var compile_id: int = pr["compile"]
		var p_desc: String = pr["description"]

		# --- Particle Generation (combined prompt handles Godot 4 correctness) ---
		_set_node_input(gen_id, p_desc)
		_set_node_status(gen_id, "running")
		_update_status("Generating particle...")
		var raw_code := await _llm_request(p_desc, _prompts.get("particle", ""))
		if raw_code.is_empty():
			_set_node_status(gen_id, "error", "", "Generation failed")
			continue
		var code := _extract_gdscript(raw_code)
		_set_node_status(gen_id, "done", code)

		# --- Auto-complete Human Review ---
		_set_node_input(review_id, code)
		_set_node_status(review_id, "done", code)

		# --- Validate (compile-check) ---
		_set_node_input(validate_id, code)
		_set_node_status(validate_id, "running")
		_update_status("Validating particle...")
		var vresult := _validate_code(code)
		if vresult["valid"]:
			_set_node_status(validate_id, "done", code)
			_set_node_input(compile_id, code)
			_set_node_status(compile_id, "done", code)
		else:
			_set_node_status(validate_id, "error", "", vresult["error"])
			_set_node_status(compile_id, "error", "", "Upstream validation failed")

	# --- Shape generation ---
	if not shape_ids.is_empty():
		var sg: int = shape_ids["gen"]
		var sr: int = shape_ids["review"]
		var sv: int = shape_ids["validate"]
		var sc: int = shape_ids["compile"]
		var combined: String = shape_ids["combined"]

		_set_node_input(sg, combined)
		_set_node_status(sg, "running")
		_update_status("Generating shapes...")
		var raw_shape := await _llm_request(combined, _prompts.get("shape", ""))
		if raw_shape.is_empty():
			_set_node_status(sg, "error", "", "Generation failed")
		else:
			var shape_code := _extract_gdscript(raw_shape)
			_set_node_status(sg, "done", shape_code)

			_set_node_input(sr, shape_code)
			_set_node_status(sr, "done", shape_code)

			# --- Validate shapes ---
			_set_node_input(sv, shape_code)
			_set_node_status(sv, "running")
			var sv_result := _validate_code(shape_code)
			if sv_result["valid"]:
				_set_node_status(sv, "done", shape_code)
				_set_node_input(sc, shape_code)
				_set_node_status(sc, "done", shape_code)
			else:
				_set_node_status(sv, "error", "", sv_result["error"])
				_set_node_status(sc, "error", "", "Upstream validation failed")

	_finish_generating("Pipeline complete – click any node to inspect")


# ============================================================================
# Workflow Engine Integration (alternative execution path)
# ============================================================================

## The workflow YAML path for the spell authoring pipeline.
const WORKFLOW_PATH := "res://ai/workflows/spell_authoring_v1.flow.yaml"

## Run the first three steps (describe → manifest → particle gen → sanitize)
## through the declarative workflow engine instead of imperative LLM calls.
## Returns the workflow outputs dictionary, or null on failure.
##
## This is an alternative to the direct _llm_request calls above.  It
## demonstrates how an imperative chain can be replaced by a single
## `run_workflow` call.  The per-particle/shape loops still run imperatively
## because YAML workflows are static (can't express dynamic iteration).
func _run_workflow_pipeline(user_prompt: String) -> Variant:
	var executor := WorkflowExecutor.new()

	# Wire tracing signals to our graph UI nodes
	executor.node_started.connect(func(nid: String, _def: Dictionary):
		_update_status("Workflow: running %s..." % nid)
	)
	executor.node_failed.connect(func(nid: String, err: String):
		push_warning("[Workflow] Node '%s' failed: %s" % [nid, err])
	)

	var result := await executor.run_workflow(WORKFLOW_PATH, {
		"user_prompt": user_prompt,
	})

	if result.has("_error"):
		push_warning("[Workflow] %s" % str(result["_error"]))
		return null

	return result


# ============================================================================
# Code Utilities
# ============================================================================


func _extract_gdscript(text: String) -> String:
	var result := text.strip_edges()
	if result.begins_with("```gdscript"):
		result = result.substr(len("```gdscript")).strip_edges()
	elif result.begins_with("```gd"):
		result = result.substr(len("```gd")).strip_edges()
	elif result.begins_with("```"):
		result = result.substr(3).strip_edges()
	if result.ends_with("```"):
		result = result.substr(0, result.length() - 3).strip_edges()
	return result


func _parse_manifest(manifest_text: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var json_text := manifest_text
	var start := json_text.find("[")
	var end := json_text.rfind("]")
	if start >= 0 and end > start:
		json_text = json_text.substr(start, end - start + 1)

	var json := JSON.new()
	if json.parse(json_text) != OK:
		return result

	var data = json.get_data()
	if not data is Array:
		return result

	for entry in data:
		if entry is Dictionary:
			result.append({
				"type": str(entry.get("type", "unknown")),
				"description": str(entry.get("description", ""))
			})
	return result
