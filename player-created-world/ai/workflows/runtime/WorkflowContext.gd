class_name WorkflowContext
extends RefCounted
## Stores all execution state for a single workflow run.
##
## Holds inputs, per-node outputs, status, timing, and the resolved
## prompts that were sent to models (for debugging).

## Workflow inputs supplied by the caller.
var inputs: Dictionary = {}

## Per-node outputs: node_id -> Dictionary of output_key -> value
var node_outputs: Dictionary = {}

## Per-node execution metadata: node_id -> Dictionary
## Each entry contains:
##   "status":   WorkflowTypes.NodeStatus enum value
##   "start_ms": int  (Time.get_ticks_msec at start)
##   "end_ms":   int  (Time.get_ticks_msec at finish, or 0)
##   "error":    String (empty if no error)
##   "resolved_prompt": String (the prompt after template resolution, for debugging)
var node_meta: Dictionary = {}

## The raw workflow definition (as parsed Dictionary)
var workflow_def: Dictionary = {}


func _init(wf_def: Dictionary = {}, wf_inputs: Dictionary = {}) -> void:
	workflow_def = wf_def
	inputs = wf_inputs


## Initialise metadata for a node before execution.
func init_node(node_id: String) -> void:
	node_meta[node_id] = {
		"status": WorkflowTypes.NodeStatus.PENDING,
		"start_ms": 0,
		"end_ms": 0,
		"error": "",
		"resolved_prompt": "",
	}
	node_outputs[node_id] = {}


## Mark a node as running.
func start_node(node_id: String) -> void:
	if not node_meta.has(node_id):
		init_node(node_id)
	node_meta[node_id]["status"] = WorkflowTypes.NodeStatus.RUNNING
	node_meta[node_id]["start_ms"] = Time.get_ticks_msec()


## Mark a node as succeeded and store its outputs.
func finish_node(node_id: String, outputs: Dictionary) -> void:
	node_meta[node_id]["status"] = WorkflowTypes.NodeStatus.SUCCEEDED
	node_meta[node_id]["end_ms"] = Time.get_ticks_msec()
	node_outputs[node_id] = outputs


## Mark a node as failed.
func fail_node(node_id: String, error: String) -> void:
	node_meta[node_id]["status"] = WorkflowTypes.NodeStatus.FAILED
	node_meta[node_id]["end_ms"] = Time.get_ticks_msec()
	node_meta[node_id]["error"] = error
	node_outputs[node_id] = {}


## Mark a node as skipped (when: evaluated to false).
func skip_node(node_id: String) -> void:
	node_meta[node_id]["status"] = WorkflowTypes.NodeStatus.SKIPPED
	node_meta[node_id]["end_ms"] = Time.get_ticks_msec()
	node_outputs[node_id] = {}


## Store the resolved prompt for debugging.
func set_resolved_prompt(node_id: String, prompt: String) -> void:
	if node_meta.has(node_id):
		node_meta[node_id]["resolved_prompt"] = prompt


## Get the status of a node.
func get_node_status(node_id: String) -> int:
	if not node_meta.has(node_id):
		return WorkflowTypes.NodeStatus.PENDING
	return node_meta[node_id]["status"]


## Get the elapsed time for a node in milliseconds.
func get_node_elapsed_ms(node_id: String) -> int:
	if not node_meta.has(node_id):
		return 0
	var meta: Dictionary = node_meta[node_id]
	if meta["end_ms"] > 0:
		return meta["end_ms"] - meta["start_ms"]
	if meta["start_ms"] > 0:
		return Time.get_ticks_msec() - meta["start_ms"]
	return 0
