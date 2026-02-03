## World Selection Dialog - UI for choosing or creating a world to join
extends CanvasLayer

signal world_selected(world_id: String)
signal dialog_closed

@onready var panel: PanelContainer = $Panel
@onready var world_list: ItemList = $Panel/VBox/WorldListContainer/WorldList
@onready var refresh_btn: Button = $Panel/VBox/WorldListContainer/RefreshBtn
@onready var create_container: HBoxContainer = $Panel/VBox/CreateContainer
@onready var world_name_input: LineEdit = $Panel/VBox/CreateContainer/WorldNameInput
@onready var create_btn: Button = $Panel/VBox/CreateContainer/CreateBtn
@onready var join_btn: Button = $Panel/VBox/JoinBtn
@onready var cancel_btn: Button = $Panel/VBox/CancelBtn
@onready var status_label: Label = $Panel/VBox/StatusLabel

## Cached world data
var _worlds: Array = []

## Net node reference
var _net: Node = null


func _ready() -> void:
	# Connect button signals
	refresh_btn.pressed.connect(_on_refresh_pressed)
	create_btn.pressed.connect(_on_create_pressed)
	join_btn.pressed.connect(_on_join_pressed)
	cancel_btn.pressed.connect(_on_cancel_pressed)
	world_name_input.text_submitted.connect(_on_world_name_submitted)
	world_name_input.text_changed.connect(_on_world_name_changed)
	world_list.item_selected.connect(_on_world_selected)
	world_list.item_activated.connect(_on_world_activated)
	
	# Get Net reference
	_net = get_node_or_null("/root/Net")
	if _net:
		_net.world_list_received.connect(_on_world_list_received)
		_net.world_created.connect(_on_world_created)
		_net.world_joined.connect(_on_world_joined)
	
	# Hide by default
	visible = false
	
	# Set placeholder
	world_name_input.placeholder_text = "Enter world name..."


func show_dialog() -> void:
	visible = true
	_update_status("Select a world or create a new one", Color.WHITE)
	
	# Request world list
	if _net and _net.is_connected_to_server():
		_net.request_world_list()
		_update_status("Loading worlds...", Color.CYAN)
	
	# Enable/disable buttons
	_update_button_states()


func hide_dialog() -> void:
	visible = false
	dialog_closed.emit()


func _update_button_states() -> void:
	var has_selection := world_list.get_selected_items().size() > 0
	join_btn.disabled = not has_selection
	
	var has_name := not world_name_input.text.strip_edges().is_empty()
	create_btn.disabled = not has_name


func _update_status(message: String, color: Color) -> void:
	status_label.text = message
	status_label.modulate = color


func _populate_world_list() -> void:
	world_list.clear()
	
	for world in _worlds:
		var world_name: String = world.get("name", "Unnamed World")
		var player_count: int = world.get("player_count", 0)
		var wid: String = world.get("world_id", "")
		
		var display := "%s (%d players)" % [world_name, player_count]
		world_list.add_item(display)
		world_list.set_item_metadata(world_list.item_count - 1, wid)
	
	_update_button_states()


# ============================================================================
# Signal Handlers - UI
# ============================================================================

func _on_refresh_pressed() -> void:
	if _net and _net.is_connected_to_server():
		_net.request_world_list()
		_update_status("Refreshing...", Color.CYAN)


func _on_create_pressed() -> void:
	var new_world_name := world_name_input.text.strip_edges()
	if new_world_name.is_empty():
		_update_status("Please enter a world name", Color.ORANGE)
		return
	
	if new_world_name.length() > 50:
		_update_status("World name must be 50 characters or less", Color.ORANGE)
		return
	
	if _net and _net.is_connected_to_server():
		# join_world with empty world_id creates a new world
		_net.join_world("", new_world_name)
		_update_status("Creating world...", Color.CYAN)
		world_name_input.text = ""
		_update_button_states()


func _on_world_name_submitted(_text: String) -> void:
	_on_create_pressed()


func _on_world_name_changed(_new_text: String) -> void:
	_update_button_states()


func _on_join_pressed() -> void:
	var selected := world_list.get_selected_items()
	if selected.is_empty():
		_update_status("Please select a world", Color.ORANGE)
		return
	
	var world_id: String = world_list.get_item_metadata(selected[0])
	if world_id.is_empty():
		return
	
	if _net and _net.is_connected_to_server():
		_net.join_world(world_id)
		_update_status("Joining world...", Color.CYAN)


func _on_cancel_pressed() -> void:
	hide_dialog()


func _on_world_selected(_index: int) -> void:
	_update_button_states()


func _on_world_activated(index: int) -> void:
	# Double-click to join
	var world_id: String = world_list.get_item_metadata(index)
	if world_id.is_empty():
		return
	
	if _net and _net.is_connected_to_server():
		_net.join_world(world_id)
		_update_status("Joining world...", Color.CYAN)


# ============================================================================
# Signal Handlers - Network
# ============================================================================

func _on_world_list_received(worlds: Array) -> void:
	_worlds = worlds
	_populate_world_list()
	
	if _worlds.is_empty():
		_update_status("No worlds found. Create one!", Color.YELLOW)
	else:
		_update_status("Select a world or create a new one", Color.WHITE)


func _on_world_created(world: Dictionary) -> void:
	var world_name: String = world.get("name", "Unknown")
	_update_status("World '%s' created! Joining..." % world_name, Color.LIME)
	
	# Auto-join the created world
	var world_id: String = world.get("world_id", "")
	if not world_id.is_empty() and _net:
		_net.join_world(world_id)


func _on_world_joined(world_id: String, world: Dictionary) -> void:
	var world_name: String = world.get("name", "Unknown")
	_update_status("Joined world: " + world_name, Color.LIME)
	world_selected.emit(world_id)
	
	# Auto-hide after success
	await get_tree().create_timer(0.5).timeout
	hide_dialog()


# ============================================================================
# Input
# ============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			hide_dialog()
			get_viewport().set_input_as_handled()
