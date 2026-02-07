extends Node

const DEFAULT_USERNAME := "EditorUser"
const DEFAULT_WORLD_NAME := "Editor World"

var _pending_world_join: bool = false

func _ready() -> void:
	if not OS.has_feature("editor") or Engine.is_editor_hint():
		return
	if _auto_connect_disabled():
		return
	_apply_control_plane_override()
	Net.authenticated.connect(_on_authenticated)
	Net.world_list_received.connect(_on_world_list_received)
	Net.world_joined.connect(_on_world_joined)
	Net.connection_failed.connect(_on_connection_failed)
	call_deferred("_start_login")

func _start_login() -> void:
	if Net.is_connected_to_server():
		return
	var username := _get_username()
	Net.login(username)

func _on_authenticated(_session_token: String, _client_id: String) -> void:
	if _pending_world_join:
		return
	_pending_world_join = true
	var world_id_override := OS.get_environment("UGCWORLD_EDITOR_WORLD_ID")
	if world_id_override != "":
		Net.join_world(world_id_override, "")
		return
	Net.request_world_list()

func _on_world_list_received(worlds: Array) -> void:
	if not _pending_world_join:
		return
	var target_name := _get_world_name()
	for world in worlds:
		if world is Dictionary and world.get("name", "") == target_name:
			Net.join_world(world.get("world_id", ""), "")
			return
	Net.join_world("", target_name)

func _on_world_joined(_world_id: String, _world: Dictionary) -> void:
	_pending_world_join = false

func _on_connection_failed(reason: String) -> void:
	_pending_world_join = false
	push_warning("[EditorAutoClient] Connection failed: %s" % reason)

func _apply_control_plane_override() -> void:
	var override := OS.get_environment("UGCWORLD_CONTROL_PLANE")
	if override != "":
		Net.control_plane_url = override

func _get_username() -> String:
	var value := OS.get_environment("UGCWORLD_EDITOR_USERNAME")
	return value if value != "" else DEFAULT_USERNAME

func _get_world_name() -> String:
	var value := OS.get_environment("UGCWORLD_EDITOR_WORLD")
	return value if value != "" else DEFAULT_WORLD_NAME

func _auto_connect_disabled() -> bool:
	var value := OS.get_environment("UGCWORLD_AUTOCONNECT").to_lower()
	return value == "0" or value == "false"
