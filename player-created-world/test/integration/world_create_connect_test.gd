extends GdUnitTestSuite

const TIMEOUT_SECONDS := 20.0

var _server_pid: int = -1
var _signal_flags: Dictionary = {}

func after_each() -> void:
	_cleanup_process()

func test_world_create_and_connect() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var port := _random_port()
	var base_url := "http://127.0.0.1:%d" % port

	var project_dir := ProjectSettings.globalize_path("res://")
	var repo_root := project_dir.get_base_dir()
	var app_path := repo_root.path_join("server_python").path_join("app.py")

	_set_env_defaults(port)
	_server_pid = OS.create_process("python", PackedStringArray([app_path]))
	assert_gt(_server_pid, 0, "Failed to start control plane server.")

	var healthy := await _wait_for_health(base_url)
	assert_true(healthy, "Control plane health check failed.")

	if Net.is_connected_to_server():
		Net.disconnect_from_server()
		await tree.process_frame

	Net.control_plane_url = base_url
	Net.login("TestUser")
	var auth_ok := await _await_signal(Net, "authenticated", 10.0)
	assert_true(auth_ok, "Login did not complete.")

	Net.join_world("", "Test World")
	var joined_ok := await _await_signal(Net, "connected_to_game_server", 15.0)
	assert_true(joined_ok, "Failed to connect to game server.")
	assert_true(Net.is_in_world(), "Client did not enter world.")

	var world_id := Net.get_current_world_id()
	assert_true(world_id != "", "World ID not set after join.")

	await _stop_world(base_url, world_id)
	Net.disconnect_from_server()

func _set_env_defaults(port: int) -> void:
	OS.set_environment("PORT", str(port))
	OS.set_environment("HOST", "127.0.0.1")
	if OS.get_environment("GODOT_PATH") == "":
		var godot_bin := OS.get_environment("GODOT_BIN")
		if godot_bin != "":
			OS.set_environment("GODOT_PATH", godot_bin)

func _wait_for_health(base_url: String) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var ok := await _http_request(base_url + "/healthz", HTTPClient.METHOD_GET)
		if ok:
			return true
		await tree.create_timer(0.5).timeout
	return false

func _stop_world(base_url: String, world_id: String) -> void:
	if world_id == "":
		return
	await _http_request(base_url + "/admin/servers/" + world_id, HTTPClient.METHOD_DELETE)

func _http_request(url: String, method: int) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var http := HTTPRequest.new()
	tree.root.add_child(http)
	var err := http.request(url, [], method)
	if err != OK:
		http.queue_free()
		return false
	var result = await http.request_completed
	http.queue_free()
	var response_code := int(result[1])
	return response_code >= 200 and response_code < 300

func _await_signal(target: Object, signal_name: String, timeout: float) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	_signal_flags[signal_name] = false
	var callback := Callable(self, "_on_signal_received").bind(signal_name)
	if target.is_connected(signal_name, callback):
		target.disconnect(signal_name, callback)
	target.connect(signal_name, callback, CONNECT_ONE_SHOT)
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(_signal_flags.get(signal_name, false)):
			return true
		await tree.process_frame
	return false

func _on_signal_received(signal_name: String, _a = null, _b = null, _c = null, _d = null) -> void:
	_signal_flags[signal_name] = true

func _cleanup_process() -> void:
	if _server_pid > 0 and OS.is_process_running(_server_pid):
		OS.kill(_server_pid)
	_server_pid = -1

func _random_port() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return rng.randi_range(5001, 9000)
