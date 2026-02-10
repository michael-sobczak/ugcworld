class_name TransformTextNode
extends RefCounted
## Node handler for "transform.text" — simple text transformation operations.
##
## Node def fields used:
##   args.op     — operation: "concat" | "regex_replace" | "json_parse" | "json_stringify"
##   args.input  — template string to transform (resolved before op)
##   args.inputs — array of template strings (for concat)
##   args.separator — separator for concat (default: "")
##   args.pattern — regex pattern (for regex_replace)
##   args.replacement — replacement string (for regex_replace)


func run(ctx: WorkflowContext, node_def: Dictionary) -> Dictionary:
	var args_raw: Variant = node_def.get("args", {})
	var args: Dictionary = args_raw as Dictionary if args_raw is Dictionary else {}

	var op: String = str(args.get("op", ""))

	match op:
		"concat":
			return _op_concat(ctx, args)
		"regex_replace":
			return _op_regex_replace(ctx, args)
		"json_parse":
			return _op_json_parse(ctx, args)
		"json_stringify":
			return _op_json_stringify(ctx, args)
		_:
			return {"text": "", "_error": "Unknown transform op: '%s'" % op}


func _op_concat(ctx: WorkflowContext, args: Dictionary) -> Dictionary:
	var inputs_raw: Variant = args.get("inputs", [])
	var inputs: Array = inputs_raw as Array if inputs_raw is Array else []
	var sep: String = str(args.get("separator", ""))
	var parts: PackedStringArray = []
	for item in inputs:
		parts.append(WorkflowTemplate.resolve(str(item), ctx))
	return {"text": sep.join(parts)}


func _op_regex_replace(ctx: WorkflowContext, args: Dictionary) -> Dictionary:
	var input: String = WorkflowTemplate.resolve(str(args.get("input", "")), ctx)
	var pattern: String = str(args.get("pattern", ""))
	var replacement: String = str(args.get("replacement", ""))

	var regex := RegEx.new()
	var err: int = regex.compile(pattern)
	if err != OK:
		return {"text": input, "_error": "Invalid regex pattern: '%s'" % pattern}

	var result: String = regex.sub(input, replacement, true)
	return {"text": result}


func _op_json_parse(ctx: WorkflowContext, args: Dictionary) -> Dictionary:
	var input: String = WorkflowTemplate.resolve(str(args.get("input", "")), ctx)
	var json := JSON.new()
	var err: int = json.parse(input)
	if err != OK:
		return {"json": null, "_error": "JSON parse error: %s" % json.get_error_message()}
	return {"json": json.get_data()}


func _op_json_stringify(ctx: WorkflowContext, args: Dictionary) -> Dictionary:
	var input: Variant = args.get("input", {})
	# If input is a template string, resolve it; otherwise use as-is
	if input is String:
		input = WorkflowTemplate.resolve(input as String, ctx)
	return {"text": JSON.stringify(input)}
