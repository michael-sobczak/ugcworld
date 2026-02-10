class_name WorkflowTypes
extends RefCounted
## Typed structures and constants for the workflow system.

## Node execution status
enum NodeStatus { PENDING, RUNNING, SUCCEEDED, FAILED, SKIPPED }

## Supported input types
const VALID_INPUT_TYPES := ["string", "int", "float", "bool", "array", "dict"]

## Supported node types
const VALID_NODE_TYPES := ["llm.chat", "tool.http", "transform.text", "control.noop"]


## Convert a NodeStatus enum to a human-readable string.
static func status_to_string(status: int) -> String:
	match status:
		NodeStatus.PENDING: return "pending"
		NodeStatus.RUNNING: return "running"
		NodeStatus.SUCCEEDED: return "succeeded"
		NodeStatus.FAILED: return "failed"
		NodeStatus.SKIPPED: return "skipped"
		_: return "unknown"
