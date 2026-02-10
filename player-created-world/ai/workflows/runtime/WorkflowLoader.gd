class_name WorkflowLoader
extends RefCounted
## Loads and validates workflow YAML files.
##
## Usage:
##   var result: Dictionary = WorkflowLoader.load_workflow("res://ai/workflows/my_flow.flow.yaml")
##   if (result["error"] as String).is_empty():
##       var workflow_dict: Dictionary = result["workflow"]


## Load a workflow from a YAML file path.
## Returns { "workflow": Dictionary, "error": String }.
static func load_workflow(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"workflow": {}, "error": "File not found: %s" % path}

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"workflow": {}, "error": "Cannot open file: %s" % path}

	var text: String = file.get_as_text()
	file.close()

	return parse_workflow(text)


## Parse a workflow from a YAML string.
## Returns { "workflow": Dictionary, "error": String }.
static func parse_workflow(yaml_text: String) -> Dictionary:
	var parsed: Variant = SimpleYAML.parse(yaml_text)
	if parsed == null:
		return {"workflow": {}, "error": "Failed to parse YAML"}
	if not parsed is Dictionary:
		return {"workflow": {}, "error": "Workflow root must be a YAML mapping"}

	var wf: Dictionary = parsed as Dictionary

	# Field-level validation
	var errors: PackedStringArray = WorkflowGraph.validate(wf)
	if not errors.is_empty():
		return {"workflow": wf, "error": "; ".join(errors)}

	return {"workflow": wf, "error": ""}


## Load a workflow and immediately validate it, returning all issues.
## Returns { "workflow": Dictionary, "errors": PackedStringArray }.
static func load_and_validate(path: String) -> Dictionary:
	var load_result: Dictionary = load_workflow(path)
	if not (load_result["error"] as String).is_empty():
		return {"workflow": load_result["workflow"], "errors": PackedStringArray([load_result["error"]])}

	var wf: Dictionary = load_result["workflow"] as Dictionary
	var errors: PackedStringArray = WorkflowGraph.validate(wf)
	return {"workflow": wf, "errors": errors}
