class_name LLMChatNode
extends RefCounted
## Node handler for "llm.chat" — sends a prompt to the LLM and returns text.
##
## Integrates with the existing LocalLLMService autoload.
##
## Node def fields used:
##   prompt            — template string for the user prompt
##   system_prompt     — template string for the system prompt
##   system_prompt_file — path to a file containing the system prompt
##   model.params      — optional overrides (max_tokens, temperature, etc.)
##   args.max_tokens   — alternative location for max_tokens
##   args.temperature  — alternative location for temperature


func run(ctx: WorkflowContext, node_def: Dictionary) -> Dictionary:
	# Resolve prompt
	var prompt_template: String = str(node_def.get("prompt", ""))
	var prompt: String = WorkflowTemplate.resolve(prompt_template, ctx)

	if prompt.strip_edges().is_empty():
		return {"text": "", "_error": "Empty prompt after template resolution"}

	# Resolve system prompt (inline or from file)
	var system_prompt: String = ""
	if node_def.has("system_prompt"):
		system_prompt = WorkflowTemplate.resolve(str(node_def["system_prompt"]), ctx)
	elif node_def.has("system_prompt_file"):
		var sp_path: String = str(node_def["system_prompt_file"])
		if FileAccess.file_exists(sp_path):
			var f: FileAccess = FileAccess.open(sp_path, FileAccess.READ)
			if f:
				system_prompt = f.get_as_text()
				f.close()

	# Store resolved prompt for debugging
	ctx.set_resolved_prompt(str(node_def["id"]), prompt)

	# Build request params
	var params: Dictionary = {}
	if node_def.has("model") and node_def["model"] is Dictionary:
		var model_def: Dictionary = node_def["model"]
		if model_def.has("params") and model_def["params"] is Dictionary:
			params = (model_def["params"] as Dictionary).duplicate()

	# Allow args to override params
	var args: Variant = node_def.get("args", {})
	if args is Dictionary:
		var args_dict: Dictionary = args as Dictionary
		if args_dict.has("max_tokens"):
			params["max_tokens"] = int(args_dict["max_tokens"])
		if args_dict.has("temperature"):
			params["temperature"] = float(args_dict["temperature"])

	# Call the LLM via LocalLLMService
	var llm: Node = _get_llm_service()
	if llm == null:
		return {"text": "", "_error": "LocalLLMService not available"}

	var request: Dictionary = {
		"prompt": prompt,
		"system_prompt": system_prompt,
		"max_tokens": params.get("max_tokens", 1024),
		"temperature": params.get("temperature", 0.7),
	}

	var handle: Variant = llm.generate_streaming(request)
	if handle == null:
		return {"text": "", "_error": "LLM generation returned null handle"}

	# Await completion
	var text: String = await _await_handle(handle)
	return {"text": text}


func _get_llm_service() -> Node:
	# Autoloads are children of /root in the scene tree
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree and tree.root:
		return tree.root.get_node_or_null("LocalLLMService")
	return null


func _await_handle(handle: Variant) -> String:
	if handle == null:
		return ""
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return ""
	# Poll until done
	while handle.get_status() == 0 or handle.get_status() == 1:
		await tree.process_frame
	if handle.get_status() == 2:  # Completed
		return handle.get_full_text()
	return ""
