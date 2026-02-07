extends GdUnitTestSuite

const TIMEOUT_SECONDS := 30.0
const JOB_TIMEOUT_SECONDS := 60.0
const SPELL_ID := "test_spell_ci"

var _server_pid: int = -1
var _base_url: String = ""
var _world_id: String = ""

var _auth_ok: bool = false
var _connected_ok: bool = false
var _revision_ready: bool = false
var _revision_id: String = ""
var _active_update: bool = false
var _active_revision_id: String = ""
var _cast_complete: bool = false
var _cast_failed: bool = false
var _cast_error: String = ""

func after_each() -> void:
	await _stop_world()
	_disconnect()
	_cleanup_process()

func test_spell_build_publish_cast() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var port := _find_free_port(20001, 28000)
	_base_url = "http://127.0.0.1:%d" % port
	_set_env_defaults(port)

	var app_path := _get_control_plane_path()
	_server_pid = OS.create_process("python", PackedStringArray([app_path]))
	assert_gt(_server_pid, 0, "Failed to start control plane server.")

	var healthy := await _wait_for_health()
	assert_true(healthy, "Control plane health check failed.")

	var net := get_node("/root/Net") as Node
	var spell_net := get_node("/root/SpellNet") as Node
	var spell_cast := get_node("/root/SpellCastController") as Node
	assert_true(net != null and spell_net != null and spell_cast != null, "Missing spell singletons.")

	_reset_flags()
	_connect_net_signals(net)
	_connect_spell_signals(spell_net, spell_cast)

	net.disconnect_from_server()
	await tree.process_frame

	net.control_plane_url = _base_url
	net.login("TestSpellUser")
	assert_true(await _wait_for_flag("_auth_ok", TIMEOUT_SECONDS), "Login did not complete.")

	net.join_world("", "Test Spell World")
	assert_true(await _wait_for_flag("_connected_ok", TIMEOUT_SECONDS), "Failed to connect to game server.")

	_world_id = net.get_current_world_id()
	assert_true(_world_id != "", "World ID not set after join.")

	spell_cast.scene_root = tree.root

	var code := _minimal_spell_code(SPELL_ID)
	spell_net.start_build(SPELL_ID, {
		"code": code,
		"metadata": {
			"name": "Test Spell",
			"description": "CI build/publish/cast test"
		}
	})
	assert_true(await _wait_for_flag("_revision_ready", JOB_TIMEOUT_SECONDS), "Revision was not created.")
	assert_true(_revision_id != "", "Revision ID missing after build.")

	spell_net.publish_revision(SPELL_ID, _revision_id, "beta")
	assert_true(await _wait_for_flag("_active_update", TIMEOUT_SECONDS), "Spell publish did not update active revision.")
	assert_true(_active_revision_id == _revision_id, "Active revision mismatch after publish.")

	spell_cast.cast_spell(SPELL_ID, Vector3.ZERO, {})
	var cast_ok := await _wait_for_flag("_cast_complete", TIMEOUT_SECONDS)
	assert_true(cast_ok, "Spell cast did not complete.")
	assert_false(_cast_failed, "Spell cast failed: %s" % _cast_error)

func _set_env_defaults(port: int) -> void:
	OS.set_environment("PORT", str(port))
	OS.set_environment("HOST", "127.0.0.1")
	if OS.get_environment("GODOT_PATH") == "":
		var godot_bin := OS.get_environment("GODOT_BIN")
		if godot_bin != "":
			OS.set_environment("GODOT_PATH", godot_bin)
	if OS.get_environment("GAME_SERVER_PATH") == "":
		var project_dir := ProjectSettings.globalize_path("res://")
		var repo_root := project_dir.get_base_dir()
		OS.set_environment("GAME_SERVER_PATH", repo_root.path_join("server_godot"))

func _get_control_plane_path() -> String:
	var project_dir := ProjectSettings.globalize_path("res://")
	var repo_root := project_dir.get_base_dir()
	return repo_root.path_join("server_python").path_join("app.py")

func _wait_for_health() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if await _http_request("/healthz", HTTPClient.METHOD_GET):
			return true
		await tree.create_timer(0.5).timeout
	return false

func _http_request(path: String, method: int, body: Dictionary = {}) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var http: HTTPRequest = HTTPRequest.new()
	tree.root.add_child(http)
	var url: String = _base_url + path
	var headers: Array[String] = ["Content-Type: application/json"]
	var err: int = OK
	if body.is_empty():
		err = http.request(url, headers, method)
	else:
		err = http.request(url, headers, method, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		return false
	var result: Array = await http.request_completed
	http.queue_free()
	var response_code := int(result[1])
	return response_code >= 200 and response_code < 300

func _stop_world() -> void:
	if _world_id == "":
		return
	await _http_request("/admin/servers/" + _world_id, HTTPClient.METHOD_DELETE)
	_world_id = ""

func _disconnect() -> void:
	var net := get_node_or_null("/root/Net")
	if net:
		net.disconnect_from_server()

func _cleanup_process() -> void:
	if _server_pid > 0 and OS.is_process_running(_server_pid):
		OS.kill(_server_pid)
	_server_pid = -1

func _find_free_port(min_port: int, max_port: int) -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var attempts := 50
	for _i in range(attempts):
		var candidate := rng.randi_range(min_port, max_port)
		if not _is_port_in_use(candidate):
			return candidate
	return rng.randi_range(min_port, max_port)

func _is_port_in_use(port: int) -> bool:
	var peer := StreamPeerTCP.new()
	var err := peer.connect_to_host("127.0.0.1", port)
	if err == OK:
		peer.disconnect_from_host()
		return true
	if err == ERR_BUSY:
		return true
	return false

func _reset_flags() -> void:
	_auth_ok = false
	_connected_ok = false
	_revision_ready = false
	_revision_id = ""
	_active_update = false
	_active_revision_id = ""
	_cast_complete = false
	_cast_failed = false
	_cast_error = ""

func _connect_net_signals(net: Node) -> void:
	var auth_cb := Callable(self, "_on_authenticated")
	if net.is_connected("authenticated", auth_cb):
		net.disconnect("authenticated", auth_cb)
	net.connect("authenticated", auth_cb)

	var conn_cb := Callable(self, "_on_connected")
	if net.is_connected("connected_to_game_server", conn_cb):
		net.disconnect("connected_to_game_server", conn_cb)
	net.connect("connected_to_game_server", conn_cb)

func _connect_spell_signals(spell_net: Node, spell_cast: Node) -> void:
	var rev_cb := Callable(self, "_on_revision_ready")
	if spell_net.is_connected("spell_revision_ready", rev_cb):
		spell_net.disconnect("spell_revision_ready", rev_cb)
	spell_net.connect("spell_revision_ready", rev_cb)

	var active_cb := Callable(self, "_on_spell_active_update")
	if spell_net.is_connected("spell_active_update", active_cb):
		spell_net.disconnect("spell_active_update", active_cb)
	spell_net.connect("spell_active_update", active_cb)

	var complete_cb := Callable(self, "_on_cast_complete")
	if spell_cast.is_connected("spell_cast_complete", complete_cb):
		spell_cast.disconnect("spell_cast_complete", complete_cb)
	spell_cast.connect("spell_cast_complete", complete_cb)

	var failed_cb := Callable(self, "_on_cast_failed")
	if spell_cast.is_connected("spell_cast_failed", failed_cb):
		spell_cast.disconnect("spell_cast_failed", failed_cb)
	spell_cast.connect("spell_cast_failed", failed_cb)

func _wait_for_flag(flag_name: String, timeout: float) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(get(flag_name)):
			return true
		await tree.process_frame
	return false

func _on_authenticated(_session_token: String, _client_id: String) -> void:
	_auth_ok = true

func _on_connected() -> void:
	_connected_ok = true

func _on_revision_ready(spell_id: String, revision_id: String, _manifest: Dictionary) -> void:
	if spell_id == SPELL_ID:
		_revision_ready = true
		_revision_id = revision_id

func _on_spell_active_update(spell_id: String, revision_id: String, _channel: String, _manifest: Dictionary) -> void:
	if spell_id == SPELL_ID:
		_active_update = true
		_active_revision_id = revision_id

func _on_cast_complete(spell_id: String, revision_id: String) -> void:
	if spell_id == SPELL_ID:
		_cast_complete = true
		_active_revision_id = revision_id

func _on_cast_failed(spell_id: String, error_msg: String) -> void:
	if spell_id == SPELL_ID:
		_cast_failed = true
		_cast_error = error_msg

func _minimal_spell_code(spell_id: String) -> String:
	return """extends SpellModule
## Minimal test spell

func get_manifest() -> Dictionary:
	return {
		"spell_id": "%s",
		"name": "Test Spell",
		"description": "Test spell for CI"
	}

func on_cast(_ctx: SpellContext) -> void:
	pass
""" % spell_id
