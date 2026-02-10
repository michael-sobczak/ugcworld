extends GdUnitTestSuite
## Self-tests for the workflow engine subsystems.


# ============================================================================
# SimpleYAML parser
# ============================================================================

func test_yaml_parse_simple_mapping() -> void:
	var yaml := "key1: hello\nkey2: 42\nkey3: true"
	var result: Variant = SimpleYAML.parse(yaml)
	assert_that(result).is_not_null()
	var d: Dictionary = result as Dictionary
	assert_eq(d["key1"], "hello")
	assert_eq(d["key2"], 42)
	assert_eq(d["key3"], true)


func test_yaml_parse_nested_mapping() -> void:
	var yaml := "outer:\n  inner: value"
	var result: Variant = SimpleYAML.parse(yaml)
	assert_that(result).is_not_null()
	var d: Dictionary = result as Dictionary
	assert_eq((d["outer"] as Dictionary)["inner"], "value")


func test_yaml_parse_block_array() -> void:
	var yaml := "items:\n  - one\n  - two\n  - three"
	var result: Variant = SimpleYAML.parse(yaml)
	assert_that(result).is_not_null()
	var d: Dictionary = result as Dictionary
	var items: Array = d["items"] as Array
	assert_eq(items.size(), 3)
	assert_eq(items[0], "one")
	assert_eq(items[2], "three")


func test_yaml_parse_flow_mapping() -> void:
	var yaml := "data: { name: test, count: 5 }"
	var result: Variant = SimpleYAML.parse(yaml)
	assert_that(result).is_not_null()
	var d: Dictionary = result as Dictionary
	var data: Dictionary = d["data"] as Dictionary
	assert_eq(data["name"], "test")
	assert_eq(data["count"], 5)


func test_yaml_parse_flow_array() -> void:
	var yaml := "tags: [alpha, beta, gamma]"
	var result: Variant = SimpleYAML.parse(yaml)
	assert_that(result).is_not_null()
	var d: Dictionary = result as Dictionary
	var tags: Array = d["tags"] as Array
	assert_eq(tags.size(), 3)
	assert_eq(tags[1], "beta")


# ============================================================================
# WorkflowTemplate
# ============================================================================

func test_template_resolve_inputs() -> void:
	var ctx: Dictionary = {"inputs": {"name": "fireball"}, "nodes": {}}
	var result: String = WorkflowTemplate.resolve("Cast {{inputs.name}} spell", ctx)
	assert_eq(result, "Cast fireball spell")


func test_template_resolve_nodes() -> void:
	var ctx: Dictionary = {"inputs": {}, "nodes": {"step1": {"text": "hello world"}}}
	var result: String = WorkflowTemplate.resolve("Output: {{nodes.step1.text}}", ctx)
	assert_eq(result, "Output: hello world")


func test_template_resolve_default_filter() -> void:
	var ctx: Dictionary = {"inputs": {}, "nodes": {}}
	var result: String = WorkflowTemplate.resolve("{{inputs.missing | default(\"fallback\")}}", ctx)
	assert_eq(result, "fallback")


func test_template_resolve_no_template() -> void:
	var ctx: Dictionary = {"inputs": {}, "nodes": {}}
	var result: String = WorkflowTemplate.resolve("plain text no templates", ctx)
	assert_eq(result, "plain text no templates")


func test_template_resolve_bool_true() -> void:
	var ctx: Dictionary = {"inputs": {"flag": "yes"}, "nodes": {}}
	assert_bool(WorkflowTemplate.resolve_bool("{{inputs.flag}}", ctx)).is_true()


func test_template_resolve_bool_false() -> void:
	var ctx: Dictionary = {"inputs": {"flag": "false"}, "nodes": {}}
	assert_bool(WorkflowTemplate.resolve_bool("{{inputs.flag}}", ctx)).is_false()


func test_template_resolve_bool_missing() -> void:
	var ctx: Dictionary = {"inputs": {}, "nodes": {}}
	assert_bool(WorkflowTemplate.resolve_bool("{{inputs.missing}}", ctx)).is_false()


# ============================================================================
# WorkflowGraph (DAG / topological sort)
# ============================================================================

func test_topo_sort_linear() -> void:
	var nodes: Array = [
		{"id": "a", "needs": []},
		{"id": "b", "needs": ["a"]},
		{"id": "c", "needs": ["b"]},
	]
	var result: Dictionary = WorkflowGraph.topological_sort(nodes)
	assert_eq(result["error"], "")
	var order: Array = result["order"] as Array
	assert_eq(order.size(), 3)
	assert_eq(order[0], "a")
	assert_eq(order[1], "b")
	assert_eq(order[2], "c")


func test_topo_sort_parallel() -> void:
	var nodes: Array = [
		{"id": "root"},
		{"id": "branch_a", "needs": ["root"]},
		{"id": "branch_b", "needs": ["root"]},
		{"id": "merge", "needs": ["branch_a", "branch_b"]},
	]
	var result: Dictionary = WorkflowGraph.topological_sort(nodes)
	assert_eq(result["error"], "")
	var order: Array = result["order"] as Array
	assert_eq(order[0], "root")
	assert_eq(order[3], "merge")
	# branch_a and branch_b can be in either order (deterministic alphabetical)
	assert_bool(order[1] == "branch_a").is_true()
	assert_bool(order[2] == "branch_b").is_true()


func test_topo_sort_detects_cycle() -> void:
	var nodes: Array = [
		{"id": "a", "needs": ["c"]},
		{"id": "b", "needs": ["a"]},
		{"id": "c", "needs": ["b"]},
	]
	var result: Dictionary = WorkflowGraph.topological_sort(nodes)
	assert_bool((result["error"] as String).is_empty()).is_false()
	assert_bool((result["error"] as String).find("Cycle") >= 0).is_true()


func test_topo_sort_missing_dependency() -> void:
	var nodes: Array = [
		{"id": "a", "needs": ["nonexistent"]},
	]
	var result: Dictionary = WorkflowGraph.topological_sort(nodes)
	assert_bool((result["error"] as String).is_empty()).is_false()


# ============================================================================
# WorkflowGraph.validate
# ============================================================================

func test_validate_minimal_valid() -> void:
	var wf: Dictionary = {
		"id": "test",
		"version": 1,
		"nodes": [
			{"id": "n1", "type": "control.noop"},
		],
		"outputs": {},
	}
	var errors: PackedStringArray = WorkflowGraph.validate(wf)
	assert_eq(errors.size(), 0)


func test_validate_missing_id() -> void:
	var wf: Dictionary = {"version": 1, "nodes": [{"id": "n1", "type": "control.noop"}], "outputs": {}}
	var errors: PackedStringArray = WorkflowGraph.validate(wf)
	assert_bool(errors.size() > 0).is_true()


func test_validate_unknown_node_type() -> void:
	var wf: Dictionary = {
		"id": "test", "version": 1,
		"nodes": [{"id": "n1", "type": "bogus.type"}],
		"outputs": {},
	}
	var errors: PackedStringArray = WorkflowGraph.validate(wf)
	assert_bool(errors.size() > 0).is_true()


# ============================================================================
# WorkflowExecutor — noop + skip via when
# ============================================================================

func test_executor_noop() -> void:
	var wf: Dictionary = {
		"id": "test", "version": 1,
		"nodes": [{"id": "n1", "type": "control.noop", "out": []}],
		"outputs": {},
	}
	var executor := WorkflowExecutor.new()
	var result: Dictionary = await executor.run_workflow_def(wf, {})
	assert_bool(result.has("_error")).is_false()
	var ctx: WorkflowContext = result["_context"] as WorkflowContext
	assert_eq(ctx.get_node_status("n1"), WorkflowTypes.NodeStatus.SUCCEEDED)


func test_executor_skip_via_when() -> void:
	var wf: Dictionary = {
		"id": "test", "version": 1,
		"inputs": {"skip": {"type": "bool", "default": false}},
		"nodes": [
			{"id": "n1", "type": "control.noop", "when": "{{inputs.skip}}"},
		],
		"outputs": {},
	}
	var executor := WorkflowExecutor.new()
	var result: Dictionary = await executor.run_workflow_def(wf, {"skip": "false"})
	var ctx: WorkflowContext = result["_context"] as WorkflowContext
	assert_eq(ctx.get_node_status("n1"), WorkflowTypes.NodeStatus.SKIPPED)


func test_executor_transform_concat() -> void:
	var wf: Dictionary = {
		"id": "test", "version": 1,
		"inputs": {"a": {"type": "string"}, "b": {"type": "string"}},
		"nodes": [
			{
				"id": "join",
				"type": "transform.text",
				"args": {
					"op": "concat",
					"inputs": ["{{inputs.a}}", " + ", "{{inputs.b}}"],
					"separator": "",
				},
				"out": ["text"],
			},
		],
		"outputs": {"result": "{{nodes.join.text}}"},
	}
	var executor := WorkflowExecutor.new()
	var result: Dictionary = await executor.run_workflow_def(wf, {"a": "fire", "b": "ice"})
	assert_eq(result["result"], "fire + ice")


func test_executor_dependency_chain() -> void:
	var wf: Dictionary = {
		"id": "test", "version": 1,
		"nodes": [
			{"id": "first", "type": "control.noop"},
			{"id": "second", "type": "control.noop", "needs": ["first"]},
		],
		"outputs": {},
	}
	var executor := WorkflowExecutor.new()

	var started_order: Array[String] = []
	executor.node_started.connect(func(nid: String, _def: Dictionary) -> void:
		started_order.append(nid)
	)

	var result: Dictionary = await executor.run_workflow_def(wf, {})
	assert_bool(result.has("_error")).is_false()
	assert_eq(started_order[0], "first")
	assert_eq(started_order[1], "second")


# ============================================================================
# Type safety — ensure all public APIs use explicit types (catches Variant
# inference issues that trigger "cannot infer type" parser errors in Godot)
# ============================================================================

func test_llm_node_get_llm_service_returns_typed() -> void:
	# _get_llm_service() must return Node (nullable), not untyped Variant
	var node := LLMChatNode.new()
	# In test env without the autoload, this should return null (not crash)
	var llm: Node = node._get_llm_service()
	assert_that(llm).is_null()


func test_workflow_loader_returns_typed_dict() -> void:
	# load_workflow on a non-existent file should return a typed dict with error
	var result: Dictionary = WorkflowLoader.load_workflow("res://nonexistent.flow.yaml")
	assert_bool((result["error"] as String).is_empty()).is_false()
	assert_bool(result.has("workflow")).is_true()


func test_context_node_status_returns_int() -> void:
	var ctx := WorkflowContext.new({}, {})
	ctx.init_node("test")
	var status: int = ctx.get_node_status("test")
	assert_eq(status, WorkflowTypes.NodeStatus.PENDING)


func test_context_elapsed_returns_int() -> void:
	var ctx := WorkflowContext.new({}, {})
	ctx.init_node("test")
	var elapsed: int = ctx.get_node_elapsed_ms("test")
	assert_eq(elapsed, 0)
