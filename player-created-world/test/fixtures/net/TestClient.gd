extends Node

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 19000
const DEFAULT_TIMEOUT := 15.0

var _log: TestLog
var _client_id: int = 0
var _scenario: String = ScenarioRunner.DEFAULT_SCENARIO
var _timeout_timer: SceneTreeTimer

func _ready() -> void:
	var args := ArgParser.parse(OS.get_cmdline_args())
	var host := ArgParser.get_string(args, "host", DEFAULT_HOST)
	var port := ArgParser.get_int(args, "port", DEFAULT_PORT)
	_client_id = ArgParser.get_int(args, "client_id", 1)
	_scenario = ArgParser.get_string(args, "scenario", ScenarioRunner.DEFAULT_SCENARIO)
	var log_path := ArgParser.get_string(args, "log", "res://artifacts/test-logs/test-client-%d.log" % _client_id)
	var timeout := ArgParser.get_float(args, "timeout", DEFAULT_TIMEOUT)

	_log = TestLog.new()
	_log.open(log_path)
	_log.info("Starting test client %d connecting to %s:%d" % [_client_id, host, port])

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, port)
	if err != OK:
		_log.error("Failed to connect client: %s" % err)
		_log.event("client_failed", {"reason": "connect_failed", "code": err})
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer

	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	_timeout_timer = get_tree().create_timer(timeout)
	_timeout_timer.timeout.connect(_on_timeout)

func _on_connected() -> void:
	_log.info("Connected to server.")
	rpc_id(1, "client_ready", _client_id)

func _on_connection_failed() -> void:
	_log.error("Connection failed.")
	_log.event("client_failed", {"reason": "connection_failed"})
	get_tree().quit(1)

func _on_server_disconnected() -> void:
	_log.warn("Server disconnected.")
	_log.event("client_failed", {"reason": "server_disconnected"})
	get_tree().quit(1)

@rpc("authority", "reliable")
func perform_action(action: Dictionary) -> void:
	_log.info("Performing action as client_%d" % _client_id)
	_log.event("perform_action", {"client_id": _client_id, "action": action})
	rpc_id(1, "submit_action", action)

@rpc("authority", "reliable")
func state_update(state: Dictionary, expected_hash: String) -> void:
	var local_hash := NetAssertions.state_hash(state)
	var ok := local_hash == expected_hash
	if ok:
		_log.info("State hash matches: %s" % local_hash)
	else:
		_log.error("State hash mismatch. local=%s expected=%s" % [local_hash, expected_hash])
	_log.event("state_checked", {"client_id": _client_id, "ok": ok, "hash": local_hash})
	rpc_id(1, "client_done", _client_id, ok, local_hash)
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0 if ok else 1)

@rpc("authority", "reliable")
func scenario_abort(reason: String) -> void:
	_log.error("Scenario aborted: %s" % reason)
	_log.event("scenario_abort", {"reason": reason})
	get_tree().quit(1)

func _on_timeout() -> void:
	_log.error("Client timed out.")
	_log.event("client_timeout", {"client_id": _client_id})
	get_tree().quit(1)
