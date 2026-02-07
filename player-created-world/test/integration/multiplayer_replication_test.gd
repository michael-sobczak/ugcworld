extends GdUnitTestSuite

const TIMEOUT_MS := 20000

func test_multiplayer_replication() -> void:
	var godot_bin := _resolve_godot_bin()
	var project_path := ProjectSettings.globalize_path("res://")
	var log_dir := ProjectSettings.globalize_path("res://artifacts/test-logs")
	DirAccess.make_dir_recursive_absolute(log_dir)

	var port := _random_port()
	var server_log := "res://artifacts/test-logs/server.log"
	var client1_log := "res://artifacts/test-logs/client1.log"
	var client2_log := "res://artifacts/test-logs/client2.log"

	var server_pid := OS.create_process(godot_bin, [
		"--headless",
		"--path", project_path,
		"--script", "res://test/fixtures/net/TestServerRunner.gd",
		"--",
		"--port=%d" % port,
		"--log=%s" % server_log,
		"--scenario=replication_basic"
	])
	assert_gt(server_pid, 0, "Failed to spawn server process.")

	var client1_pid := OS.create_process(godot_bin, [
		"--headless",
		"--path", project_path,
		"--script", "res://test/fixtures/net/TestClientRunner.gd",
		"--",
		"--port=%d" % port,
		"--client_id=1",
		"--log=%s" % client1_log,
		"--scenario=replication_basic"
	])
	assert_gt(client1_pid, 0, "Failed to spawn client1 process.")

	var client2_pid := OS.create_process(godot_bin, [
		"--headless",
		"--path", project_path,
		"--script", "res://test/fixtures/net/TestClientRunner.gd",
		"--",
		"--port=%d" % port,
		"--client_id=2",
		"--log=%s" % client2_log,
		"--scenario=replication_basic"
	])
	assert_gt(client2_pid, 0, "Failed to spawn client2 process.")

	var success := _wait_for_completion(server_log, [client1_log, client2_log])
	if not success:
		_cleanup_process(server_pid)
		_cleanup_process(client1_pid)
		_cleanup_process(client2_pid)
	assert_true(success, "Integration scenario did not complete successfully.")

func _wait_for_completion(server_log: String, client_logs: Array) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < TIMEOUT_MS:
		if _server_success(server_log) and _clients_success(client_logs):
			return true
		OS.delay_msec(250)
	return false

func _server_success(server_log: String) -> bool:
	var events := _read_events(server_log)
	for event in events:
		if event.get("event", "") == "scenario_complete":
			return bool(event.get("data", {}).get("ok", false))
	return false

func _clients_success(client_logs: Array) -> bool:
	for log_path in client_logs:
		var events := _read_events(log_path)
		var ok := false
		for event in events:
			if event.get("event", "") == "state_checked":
				ok = bool(event.get("data", {}).get("ok", false))
		if not ok:
			return false
	return true

func _read_events(log_path: String) -> Array:
	var events_path := ProjectSettings.globalize_path(log_path + ".events.jsonl")
	if not FileAccess.file_exists(events_path):
		return []
	var file := FileAccess.open(events_path, FileAccess.READ)
	if file == null:
		return []
	var results: Array = []
	while not file.eof_reached():
		var line := file.get_line()
		if line.strip_edges() == "":
			continue
		var parsed := JSON.parse_string(line)
		if parsed is Dictionary:
			results.append(parsed)
	file.close()
	return results

func _resolve_godot_bin() -> String:
	var env := OS.get_environment("GODOT_BIN")
	if env != "":
		return env
	return OS.get_executable_path()

func _random_port() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return rng.randi_range(20000, 40000)

func _cleanup_process(pid: int) -> void:
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
