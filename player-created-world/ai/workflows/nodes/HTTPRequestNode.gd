class_name HTTPRequestNode
extends RefCounted
## Node handler for "tool.http" — makes an HTTP request.
##
## Node def fields used:
##   args.url     — target URL (template-resolved)
##   args.method  — HTTP method (default: "GET")
##   args.headers — Dictionary of header key/value pairs
##   args.body    — request body string


func run(ctx: WorkflowContext, node_def: Dictionary) -> Dictionary:
	var args: Variant = node_def.get("args", {})
	if not args is Dictionary:
		args = {}
	var args_dict: Dictionary = args as Dictionary

	var url: String = WorkflowTemplate.resolve(str(args_dict.get("url", "")), ctx)
	if url.is_empty():
		return {"status": 0, "body": "", "_error": "No URL provided"}

	var method_str: String = str(args_dict.get("method", "GET")).to_upper()
	var headers_raw: Variant = args_dict.get("headers", {})
	var body: String = WorkflowTemplate.resolve(str(args_dict.get("body", "")), ctx)

	# Build headers array
	var headers: PackedStringArray = []
	if headers_raw is Dictionary:
		var headers_dict: Dictionary = headers_raw as Dictionary
		for key in headers_dict:
			headers.append("%s: %s" % [key, WorkflowTemplate.resolve(str(headers_dict[key]), ctx)])

	# Map method string to HTTPClient.Method enum
	var method: int = HTTPClient.METHOD_GET
	match method_str:
		"POST": method = HTTPClient.METHOD_POST
		"PUT": method = HTTPClient.METHOD_PUT
		"DELETE": method = HTTPClient.METHOD_DELETE
		"PATCH": method = HTTPClient.METHOD_PATCH

	# Use a temporary HTTPRequest node
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return {"status": 0, "body": "", "_error": "No scene tree available"}

	var http := HTTPRequest.new()
	tree.root.add_child(http)

	var err: int = http.request(url, headers, method, body)
	if err != OK:
		http.queue_free()
		return {"status": 0, "body": "", "_error": "HTTP request failed: %d" % err}

	# Await result
	var result: Array = await http.request_completed
	http.queue_free()

	var status_code: int = result[1]
	var response_body: String = (result[3] as PackedByteArray).get_string_from_utf8()
	return {"status": status_code, "body": response_body}
