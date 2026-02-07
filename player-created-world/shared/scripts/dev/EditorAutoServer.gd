extends Node

const DEFAULT_PORT := 5000

var _server_pid: int = -1
var _owns_server: bool = false

func _ready() -> void:
	if not OS.has_feature("editor") or Engine.is_editor_hint():
		return
	if _auto_start_disabled():
		return
	call_deferred("_ensure_server")
	tree_exiting.connect(_on_tree_exiting)

func _ensure_server() -> void:
	var port := _get_port()
	var health_url := "http://127.0.0.1:%d/healthz" % port
	var running := await _check_health(health_url)
	if running:
		print("[EditorAutoServer] Control plane already running at %s" % health_url)
		return
	_start_server(port)

func _start_server(port: int) -> void:
	var app_path := _get_control_plane_path()
	if not FileAccess.file_exists(app_path):
		push_error("[EditorAutoServer] Control plane app.py not found at %s" % app_path)
		return
	_set_env_defaults(port)

	var python_bin := OS.get_environment("PYTHON_BIN")
	if python_bin == "":
		python_bin = "python"

	_server_pid = OS.create_process(python_bin, PackedStringArray([app_path]))
	if _server_pid <= 0:
		push_error("[EditorAutoServer] Failed to start control plane.")
		_server_pid = -1
		return
	_owns_server = true
	print("[EditorAutoServer] Started control plane (pid=%d) on port %d" % [_server_pid, port])

func _check_health(url: String) -> bool:
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(url, [], HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return false
	var result = await http.request_completed
	http.queue_free()
	var response_code := int(result[1])
	return response_code >= 200 and response_code < 300

func _get_port() -> int:
	var env_port := OS.get_environment("PORT")
	if env_port != "":
		return int(env_port)
	return DEFAULT_PORT

func _set_env_defaults(port: int) -> void:
	OS.set_environment("PORT", str(port))
	OS.set_environment("HOST", "127.0.0.1")
	if OS.get_environment("GODOT_PATH") == "":
		var godot_bin := OS.get_environment("GODOT_BIN")
		OS.set_environment("GODOT_PATH", godot_bin if godot_bin != "" else OS.get_executable_path())
	if OS.get_environment("GAME_SERVER_PATH") == "":
		OS.set_environment("GAME_SERVER_PATH", _get_game_server_path())

func _get_control_plane_path() -> String:
	var project_dir := ProjectSettings.globalize_path("res://")
	var repo_root := project_dir.get_base_dir()
	return repo_root.path_join("server_python").path_join("app.py")

func _get_game_server_path() -> String:
	var project_dir := ProjectSettings.globalize_path("res://")
	var repo_root := project_dir.get_base_dir()
	return repo_root.path_join("server_godot")

func _auto_start_disabled() -> bool:
	var value := OS.get_environment("UGCWORLD_AUTOSTART_SERVER").to_lower()
	return value == "0" or value == "false"

func _on_tree_exiting() -> void:
	if _owns_server and _server_pid > 0 and OS.is_process_running(_server_pid):
		OS.kill(_server_pid)
		_server_pid = -1
