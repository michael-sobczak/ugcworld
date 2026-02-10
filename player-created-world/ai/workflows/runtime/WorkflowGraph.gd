class_name WorkflowGraph
extends RefCounted
## Builds a DAG from workflow node definitions and provides
## topological sort + cycle detection.


## Build a topological execution order from a list of node definitions.
## Each node_def must have "id" (String) and optionally "needs" (Array[String]).
## Returns { "order": Array[String], "error": String }.
## "order" contains node IDs in execution order; "error" is empty on success.
static func topological_sort(node_defs: Array) -> Dictionary:
	# Build adjacency and in-degree maps
	var in_degree: Dictionary = {}   # node_id -> int
	var dependents: Dictionary = {}  # node_id -> Array[String] (who depends on me)
	var id_set: Dictionary = {}      # node_id -> true (for quick lookup)

	for node_def_v: Variant in node_defs:
		var node_def: Dictionary = node_def_v as Dictionary
		var nid: String = str(node_def["id"])
		id_set[nid] = true
		if not in_degree.has(nid):
			in_degree[nid] = 0
		if not dependents.has(nid):
			dependents[nid] = []

	# Validate needs references and populate edges
	for node_def_v2: Variant in node_defs:
		var node_def: Dictionary = node_def_v2 as Dictionary
		var nid: String = str(node_def["id"])
		var needs_raw: Variant = node_def.get("needs", [])
		var needs: Array = needs_raw as Array if needs_raw is Array else []
		for dep: Variant in needs:
			var dep_str: String = str(dep)
			if not id_set.has(dep_str):
				return {"order": [], "error": "Node '%s' depends on unknown node '%s'" % [nid, dep_str]}
			in_degree[nid] = (in_degree[nid] as int) + 1
			if not dependents.has(dep_str):
				dependents[dep_str] = []
			(dependents[dep_str] as Array).append(nid)

	# Kahn's algorithm
	var queue: Array[String] = []
	for nid: Variant in in_degree:
		if (in_degree[nid] as int) == 0:
			queue.append(str(nid))

	var order: Array[String] = []
	while not queue.is_empty():
		# Sort queue for deterministic order among nodes with same in-degree
		queue.sort()
		var current: String = queue.pop_front()
		order.append(current)
		var deps_of_current: Variant = dependents.get(current, [])
		var deps_arr: Array = deps_of_current as Array if deps_of_current is Array else []
		for dependent: Variant in deps_arr:
			var dep_str: String = str(dependent)
			in_degree[dep_str] = (in_degree[dep_str] as int) - 1
			if (in_degree[dep_str] as int) == 0:
				queue.append(dep_str)

	if order.size() != id_set.size():
		# Find nodes involved in cycle
		var in_cycle: PackedStringArray = []
		for nid: Variant in in_degree:
			if (in_degree[nid] as int) > 0:
				in_cycle.append(str(nid))
		return {"order": [], "error": "Cycle detected involving nodes: %s" % ", ".join(in_cycle)}

	return {"order": order, "error": ""}


## Validate a workflow definition.  Returns an array of error strings (empty = valid).
static func validate(workflow: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []

	if not workflow.has("id") or str(workflow["id"]).is_empty():
		errors.append("Missing or empty 'id' field")
	if not workflow.has("version"):
		errors.append("Missing 'version' field")
	if not workflow.has("nodes"):
		errors.append("Missing 'nodes' field")
		return errors
	if not workflow["nodes"] is Array:
		errors.append("'nodes' must be an array")
		return errors

	var nodes: Array = workflow["nodes"] as Array
	var seen_ids: Dictionary = {}

	for i in range(nodes.size()):
		var node: Variant = nodes[i]
		if not node is Dictionary:
			errors.append("Node at index %d is not a mapping" % i)
			continue
		var nd: Dictionary = node as Dictionary
		if not nd.has("id"):
			errors.append("Node at index %d is missing 'id'" % i)
			continue
		var nid: String = str(nd["id"])
		if seen_ids.has(nid):
			errors.append("Duplicate node id '%s'" % nid)
		seen_ids[nid] = true

		if not nd.has("type"):
			errors.append("Node '%s' is missing 'type'" % nid)
		elif not str(nd["type"]) in WorkflowTypes.VALID_NODE_TYPES:
			errors.append("Node '%s' has unknown type '%s'" % [nid, str(nd["type"])])

	# Check DAG validity
	var sort_result: Dictionary = topological_sort(nodes)
	if not (sort_result["error"] as String).is_empty():
		errors.append(sort_result["error"] as String)

	# Validate outputs references
	if workflow.has("outputs") and workflow["outputs"] is Dictionary:
		var outputs: Dictionary = workflow["outputs"] as Dictionary
		for key: Variant in outputs:
			var tmpl: String = str(outputs[key])
			# Basic check: referenced node IDs exist
			if tmpl.find("nodes.") >= 0:
				var parts: PackedStringArray = tmpl.replace("{{", "").replace("}}", "").strip_edges().split(".")
				if parts.size() >= 2 and parts[0] == "nodes":
					if not seen_ids.has(parts[1]):
						errors.append("Output '%s' references unknown node '%s'" % [str(key), parts[1]])

	return errors
