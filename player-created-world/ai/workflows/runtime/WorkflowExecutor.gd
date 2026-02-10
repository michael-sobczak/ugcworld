class_name WorkflowExecutor
extends RefCounted
## Executes a workflow: loads YAML, builds DAG, runs nodes in topological
## order, and emits tracing signals.
##
## Usage:
##   var executor := WorkflowExecutor.new()
##   executor.node_started.connect(_on_node_started)
##   var result: Dictionary = await executor.run_workflow("res://ai/workflows/my.flow.yaml", {"input1": "val"})

## Tracing signals for UI integration.
signal node_started(node_id: String, node_def: Dictionary)
signal node_finished(node_id: String, outputs: Dictionary)
signal node_failed(node_id: String, error: String)
signal node_skipped(node_id: String)
signal workflow_finished(outputs: Dictionary)

## The node registry (maps type strings to handlers).
var registry: WorkflowNodeRegistry = WorkflowNodeRegistry.new()


## Run a workflow from a YAML file path with the given inputs.
## Returns the resolved workflow outputs dictionary, or a dict with "_error".
func run_workflow(path: String, inputs: Dictionary = {}) -> Dictionary:
	var load_result: Dictionary = WorkflowLoader.load_workflow(path)
	if not (load_result["error"] as String).is_empty():
		return {"_error": "Load failed: %s" % load_result["error"]}

	return await run_workflow_def(load_result["workflow"] as Dictionary, inputs)


## Run a workflow from an already-parsed definition dictionary.
func run_workflow_def(workflow: Dictionary, inputs: Dictionary = {}) -> Dictionary:
	# Validate
	var errors: PackedStringArray = WorkflowGraph.validate(workflow)
	if not errors.is_empty():
		return {"_error": "Validation failed: %s" % "; ".join(errors)}

	# Fill in default values for missing inputs
	var merged_inputs: Dictionary = _merge_defaults(workflow, inputs)

	# Build execution context
	var ctx := WorkflowContext.new(workflow, merged_inputs)

	# Build execution order
	var nodes: Array = workflow["nodes"] as Array
	var sort_result: Dictionary = WorkflowGraph.topological_sort(nodes)
	if not (sort_result["error"] as String).is_empty():
		return {"_error": sort_result["error"]}

	var exec_order: Array = sort_result["order"] as Array

	# Build a lookup: node_id -> node_def
	var node_map: Dictionary = {}
	for node_def in nodes:
		var nd: Dictionary = node_def as Dictionary
		node_map[str(nd["id"])] = nd

	# Initialise all nodes
	for nid in exec_order:
		ctx.init_node(str(nid))

	# Execute in topological order
	for nid in exec_order:
		var nid_str: String = str(nid)
		var node_def: Dictionary = node_map[nid_str] as Dictionary

		# Check "when" condition
		if node_def.has("when"):
			var when_expr: String = str(node_def["when"])
			if not WorkflowTemplate.resolve_bool(when_expr, ctx):
				ctx.skip_node(nid_str)
				node_skipped.emit(nid_str)
				continue

		# Check that all dependencies succeeded (not failed)
		var deps_ok := true
		var dep_needs_raw: Variant = node_def.get("needs", [])
		var dep_needs: Array = dep_needs_raw as Array if dep_needs_raw is Array else []
		for dep in dep_needs:
			var dep_status: int = ctx.get_node_status(str(dep))
			if dep_status == WorkflowTypes.NodeStatus.FAILED:
				deps_ok = false
				break

		if not deps_ok:
			ctx.fail_node(nid_str, "Dependency failed")
			node_failed.emit(nid_str, "Dependency failed")
			continue

		# Look up handler
		var type_key: String = str(node_def["type"])
		var handler: RefCounted = registry.get_handler(type_key)
		if handler == null:
			ctx.fail_node(nid_str, "Unknown node type: %s" % type_key)
			node_failed.emit(nid_str, "Unknown node type: %s" % type_key)
			continue

		# Execute
		ctx.start_node(nid_str)
		node_started.emit(nid_str, node_def)

		var outputs: Dictionary = await handler.run(ctx, node_def)

		# Check for internal error
		if outputs.has("_error") and not str(outputs["_error"]).is_empty():
			ctx.fail_node(nid_str, str(outputs["_error"]))
			node_failed.emit(nid_str, str(outputs["_error"]))
			continue

		# Validate declared outputs
		var declared_out_raw: Variant = node_def.get("out", [])
		var declared_out: Array = declared_out_raw as Array if declared_out_raw is Array else []
		for key in declared_out:
			if not outputs.has(str(key)):
				push_warning("[Workflow] Node '%s' declared output '%s' but did not produce it" % [nid_str, str(key)])

		ctx.finish_node(nid_str, outputs)
		node_finished.emit(nid_str, outputs)

	# Resolve workflow-level outputs
	var wf_outputs: Dictionary = _resolve_outputs(workflow, ctx)
	workflow_finished.emit(wf_outputs)

	# Attach context for callers who need tracing data
	wf_outputs["_context"] = ctx
	return wf_outputs


## Merge declared input defaults with caller-supplied inputs.
func _merge_defaults(workflow: Dictionary, inputs: Dictionary) -> Dictionary:
	var result: Dictionary = inputs.duplicate()
	var declared_raw: Variant = workflow.get("inputs", {})
	if not declared_raw is Dictionary:
		return result
	var declared: Dictionary = declared_raw as Dictionary
	for key in declared:
		if not result.has(key):
			var decl: Variant = declared[key]
			if decl is Dictionary:
				var decl_dict: Dictionary = decl as Dictionary
				if decl_dict.has("default"):
					result[key] = decl_dict["default"]
	return result


## Resolve workflow output templates against the context.
func _resolve_outputs(workflow: Dictionary, ctx: WorkflowContext) -> Dictionary:
	var result: Dictionary = {}
	var wf_outputs_raw: Variant = workflow.get("outputs", {})
	if not wf_outputs_raw is Dictionary:
		return result
	var wf_outputs: Dictionary = wf_outputs_raw as Dictionary
	for key in wf_outputs:
		var tmpl: String = str(wf_outputs[key])
		result[key] = WorkflowTemplate.resolve(tmpl, ctx)
	return result
