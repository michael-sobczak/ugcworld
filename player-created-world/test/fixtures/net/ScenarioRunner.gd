class_name ScenarioRunner
extends RefCounted

const DEFAULT_SCENARIO := "replication_basic"

static func build_initial_state(_scenario: String = DEFAULT_SCENARIO) -> Dictionary:
	return {
		"counter": 0,
		"last_actor": ""
	}

static func build_action(client_id: int, _scenario: String = DEFAULT_SCENARIO) -> Dictionary:
	return {
		"type": "increment",
		"by": 1,
		"actor": "client_%d" % client_id
	}

static func apply_action(state: Dictionary, action: Dictionary, _scenario: String = DEFAULT_SCENARIO) -> Dictionary:
	var next_state := state.duplicate(true)
	var by_value := int(action.get("by", 1))
	next_state["counter"] = int(next_state.get("counter", 0)) + by_value
	next_state["last_actor"] = str(action.get("actor", ""))
	return next_state
