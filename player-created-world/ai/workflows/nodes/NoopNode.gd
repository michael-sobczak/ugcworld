class_name NoopNode
extends RefCounted
## Node handler for "control.noop" — does nothing.
## Useful for debugging, placeholders, and branching targets.


func run(_ctx: WorkflowContext, _node_def: Dictionary) -> Dictionary:
	return {}
