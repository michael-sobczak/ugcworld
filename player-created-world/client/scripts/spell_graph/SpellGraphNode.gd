@tool
extends CGEGraphNode
## Logic data for a node in the spell creation graph.
##
## Each node represents a pipeline step: user input, description, manifest,
## particle code, shape code, sanitize pass, human review, compile & save.

## What kind of step this node represents
enum StepType { USER_INPUT, DESCRIPTION, ASSET_MANIFEST, PARTICLE, SHAPE, SANITIZE, HUMAN_REVIEW, VALIDATE, COMPILE_SAVE }

var step_type: int = StepType.USER_INPUT
var step_label: String = ""
var prompt_key: String = ""       ## Key into _prompts dict for the system prompt
var status: String = "pending"    ## pending | running | done | error
var input_text: String = ""       ## Input text fed into this step
var result_text: String = ""      ## Output text after generation completes
var error_text: String = ""       ## Error message if status == error


func serialize() -> Dictionary:
	var data: Dictionary = super()
	data["step_type"] = step_type
	data["step_label"] = step_label
	data["prompt_key"] = prompt_key
	data["status"] = status
	data["input_text"] = input_text
	data["result_text"] = result_text
	data["error_text"] = error_text
	return data


func deserialize(data: Dictionary) -> void:
	super(data)
	if data.has("step_type"):
		step_type = int(data["step_type"])
	if data.has("step_label"):
		step_label = str(data["step_label"])
	if data.has("prompt_key"):
		prompt_key = str(data["prompt_key"])
	if data.has("status"):
		status = str(data["status"])
	if data.has("input_text"):
		input_text = str(data["input_text"])
	if data.has("result_text"):
		result_text = str(data["result_text"])
	if data.has("error_text"):
		error_text = str(data["error_text"])


func _to_string() -> String:
	return "SpellGraphNode(id:%d, type:%d, label:'%s')" % [id, step_type, step_label]
