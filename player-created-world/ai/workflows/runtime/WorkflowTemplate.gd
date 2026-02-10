class_name WorkflowTemplate
extends RefCounted
## Template resolver for workflow expressions.
##
## Supports:
##   {{inputs.<name>}}
##   {{nodes.<node_id>.<output_key>}}
##   {{expr | default(<fallback>)}}
##
## No arbitrary code execution.


## Resolve all {{...}} expressions in a string.
## [param template] The string containing template expressions.
## [param context] A WorkflowContext (or Dictionary with "inputs" and "nodes" keys).
static func resolve(template: String, context: Variant) -> String:
	if template.find("{{") < 0:
		return template

	var result: String = template
	var safety: int = 0
	while result.find("{{") >= 0 and safety < 100:
		safety += 1
		var start: int = result.find("{{")
		var end: int = result.find("}}", start)
		if end < 0:
			break

		var expr: String = result.substr(start + 2, end - start - 2).strip_edges()
		var resolved: Variant = _resolve_expr(expr, context)
		result = result.substr(0, start) + str(resolved) + result.substr(end + 2)

	return result


## Resolve a single expression (without the {{ }} delimiters).
static func _resolve_expr(expr: String, context: Variant) -> Variant:
	# Check for | default(...) filter
	var default_val: Variant = ""
	var pipe_idx: int = expr.find("|")
	if pipe_idx >= 0:
		var filter_part: String = expr.substr(pipe_idx + 1).strip_edges()
		expr = expr.substr(0, pipe_idx).strip_edges()
		if filter_part.begins_with("default(") and filter_part.ends_with(")"):
			var inner: String = filter_part.substr(8, filter_part.length() - 9).strip_edges()
			default_val = _parse_literal(inner)

	var value: Variant = _lookup(expr, context)
	if value == null or (value is String and (value as String).is_empty()):
		return default_val
	return value


## Look up a dotted path in the context.
static func _lookup(path: String, context: Variant) -> Variant:
	var parts: PackedStringArray = path.split(".")
	if parts.is_empty():
		return null

	var root_key: String = parts[0]
	var data: Variant = null

	if context is Dictionary:
		var ctx_dict: Dictionary = context as Dictionary
		if root_key == "inputs":
			data = ctx_dict.get("inputs", {})
		elif root_key == "nodes":
			data = ctx_dict.get("nodes", {})
		else:
			return null
	elif context is WorkflowContext:
		var ctx_wf: WorkflowContext = context as WorkflowContext
		if root_key == "inputs":
			data = ctx_wf.inputs
		elif root_key == "nodes":
			data = ctx_wf.node_outputs
		else:
			return null
	else:
		return null

	# Walk remaining path segments
	for i in range(1, parts.size()):
		if data == null:
			return null
		if data is Dictionary:
			data = (data as Dictionary).get(parts[i], null)
		else:
			return null

	return data


## Resolve a template that should evaluate to a boolean (for when: clauses).
static func resolve_bool(template: String, context: Variant) -> bool:
	var resolved: String = resolve(template, context)
	var s: String = resolved.strip_edges().to_lower()
	if s == "false" or s == "0" or s == "" or s == "null" or s == "no":
		return false
	return true


## Parse a literal value from a default() filter argument.
static func _parse_literal(text: String) -> Variant:
	var s: String = text.strip_edges()
	if (s.begins_with('"') and s.ends_with('"')) or (s.begins_with("'") and s.ends_with("'")):
		return s.substr(1, s.length() - 2)
	if s.to_lower() == "true":
		return true
	if s.to_lower() == "false":
		return false
	if s.to_lower() == "null":
		return null
	if s.is_valid_int():
		return s.to_int()
	if s.is_valid_float():
		return s.to_float()
	return s
