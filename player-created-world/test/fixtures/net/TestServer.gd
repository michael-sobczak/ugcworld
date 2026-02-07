extends Node

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 19000
const DEFAULT_TIMEOUT := 15.0
const EXPECTED_CLIENTS := 2

var _log: TestLog
var _state: Dictionary = {}
var _scenario: String = ScenarioRunner.DEFAULT_SCENARIO
var _timeout_timer: SceneTreeTimer
var _client_map: Dictionary = {} # peer_id -> client_id
var _client_done: Dictionary = {} # client_id -> bool

func _ready() -> void:
	var args := ArgParser.parse(OS.get_cmdline_args())
	var port := ArgParser.get_int(args, "port", DEFAULT_PORT)
	_scenario = ArgParser.get_string(args, "scenario", ScenarioRunner.DEFAULT_SCENARIO)
	var log_path := ArgParser.get_string(args, "log", "res://artifacts/test-logs/test-server.log")
	var timeout := ArgParser.get_float(args, "timeout", DEFAULT_TIMEOUT)

	_log = TestLog.new()
	_log.open(log_path)
	_log.info("Starting test server on %s:%d" % [DEFAULT_HOST, port])

	_state = ScenarioRunner.build_initial_state(_scenario)

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, EXPECTED_CLIENTS)
	if err != OK:
		_log.error("Failed to bind server: %s" % err)
		_log.event("server_failed", {"reason": "bind_failed", "code": err})
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	_timeout_timer = get_tree().create_timer(timeout)
	_timeout_timer.timeout.connect(_on_timeout)

@rpc("any_peer", "reliable")
func client_ready(client_id: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	_client_map[peer_id] = client_id
	_log.info("Client ready: peer=%d client_id=%d" % [peer_id, client_id])
	_log.event("client_ready", {"peer_id": peer_id, "client_id": client_id})
	if _client_map.size() >= EXPECTED_CLIENTS:
		_start_scenario()

@rpc("any_peer", "reliable")
func submit_action(action: Dictionary) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	var client_id := int(_client_map.get(peer_id, -1))
	_log.info("Action received from client_%d" % client_id)
	_state = ScenarioRunner.apply_action(_state, action, _scenario)
	var hash := NetAssertions.state_hash(_state)
	_log.event("state_updated", {"state": _state, "hash": hash})
	rpc("state_update", _state, hash)

@rpc("any_peer", "reliable")
func client_done(client_id: int, ok: bool, hash: String) -> void:
	_log.info("Client done: client_%d ok=%s hash=%s" % [client_id, str(ok), hash])
	_client_done[client_id] = ok
	_log.event("client_done", {"client_id": client_id, "ok": ok, "hash": hash})
	if _client_done.size() >= EXPECTED_CLIENTS:
		_finish_scenario()

@rpc("authority", "reliable")
func perform_action(action: Dictionary) -> void:
	pass

@rpc("authority", "reliable")
func state_update(_state: Dictionary, _hash: String) -> void:
	pass

func _start_scenario() -> void:
	if _client_map.size() < EXPECTED_CLIENTS:
		return
	var first_peer := -1
	var client_id := -1
	for peer_id in _client_map.keys():
		if int(_client_map[peer_id]) == 1:
			first_peer = int(peer_id)
			client_id = 1
			break
	if first_peer == -1:
		first_peer = int(_client_map.keys()[0])
		client_id = int(_client_map[first_peer])
	var action := ScenarioRunner.build_action(client_id, _scenario)
	_log.info("Requesting action from client_%d" % client_id)
	_log.event("request_action", {"client_id": client_id, "action": action})
	rpc_id(first_peer, "perform_action", action)

func _finish_scenario() -> void:
	var ok := true
	for client_id in _client_done.keys():
		if not _client_done[client_id]:
			ok = false
			break
	if ok:
		_log.info("Scenario completed successfully.")
		_log.event("scenario_complete", {"ok": true})
		_log.close()
		get_tree().quit(0)
	else:
		_log.error("Scenario failed due to client mismatch.")
		_log.event("scenario_complete", {"ok": false})
		_log.close()
		get_tree().quit(1)

func _on_peer_connected(peer_id: int) -> void:
	_log.info("Peer connected: %d" % peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	_log.warn("Peer disconnected: %d" % peer_id)

func _on_timeout() -> void:
	_log.error("Scenario timed out.")
	_log.event("scenario_timeout", {"ok": false})
	rpc("scenario_abort", "timeout")
	_log.close()
	get_tree().quit(1)
