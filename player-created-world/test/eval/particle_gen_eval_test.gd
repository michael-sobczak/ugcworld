extends GdUnitTestSuite
## LLM Evaluation Tests — Particle Effect Code Generation
##
## These tests send prompts to a local LLM and validate that the generated
## GDScript compiles correctly and can be loaded as a scene in headless Godot.
##
## Prerequisites:
##   - LocalLLMService autoload available (LLM GDExtension built)
##   - deepseek-coder-v2 AND/OR qwen2.5-coder-14b model downloaded
##     (run: scripts/manage_models.py --download deepseek)
##     (run: scripts/manage_models.py --download coder)
##
## Run with:
##   scripts/run_tests.ps1 -Mode eval
##   scripts/run_tests.sh eval
##
## Run a single model only:
##   scripts/run_tests.ps1 -Mode eval -EvalModel deepseek-coder-v2
##   scripts/run_tests.sh eval deepseek-coder-v2
##
## Run eval tests then view results in a visual grid:
##   scripts/run_tests.ps1 -Mode eval -ShowResults
##   scripts/run_tests.sh eval --show-results
##
## View results from a previous run (no test execution):
##   scripts/run_tests.ps1 -ShowResults
##   scripts/run_tests.sh --show-results
##
## NOTE: These tests are intentionally excluded from the default "all" mode
## because they require a downloaded model and may take several minutes.


const MODEL_DEEPSEEK := "deepseek-coder-v2"
const MODEL_QWEN_CODER := "qwen2.5-coder-14b"
const PROMPT_SNOWFLAKE := "snowflake particle effect"
const PROMPT_SPARKLER := "sparkler effect"
const PROMPT_FIRE_BURST := "fire burst explosion with embers"
const PROMPT_HEALING_AURA := "green healing aura with rising sparkles"
const PROMPT_LIGHTNING := "lightning bolt impact with electric arcs"
const PROMPT_SMOKE_CLOUD := "thick smoke cloud that slowly dissipates"
const PROMPT_RAIN_SPLASH := "rain splashing on the ground with ripples"
const SYSTEM_PROMPT_PATH := "res://client/prompts/generate_particle_effect.md"

## Environment variable to restrict eval tests to a single model.
## When set (e.g. EVAL_MODEL_FILTER=deepseek-coder-v2), only tests for that
## model will execute; all others are skipped.
const ENV_MODEL_FILTER := "EVAL_MODEL_FILTER"


# ============================================================================
# Helpers
# ============================================================================

## Check if a model should be skipped based on the EVAL_MODEL_FILTER env var.
## Returns true if the test should be skipped (model doesn't match filter).
static func _should_skip_model(model_id: String) -> bool:
	var filter := OS.get_environment(ENV_MODEL_FILTER)
	if filter.is_empty():
		return false
	return filter != model_id


## Get the LocalLLMService autoload from the scene tree.
static func _get_llm() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree and tree.root:
		return tree.root.get_node_or_null("LocalLLMService")
	return null


## Wait for LocalLLMService to finish _ready() initialization.
## When running via --script, _initialize() fires before autoloads have had
## _ready() called, so is_extension_available() returns false prematurely.
## This helper waits up to `timeout_frames` process frames for the service
## to report ready (or at least to have run _ready()).
func _wait_for_llm_ready(llm: Node, timeout_frames: int = 60) -> bool:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	for i in range(timeout_frames):
		# is_ready() returns true once _ready() has completed and the
		# extension was detected, or is_extension_available() alone tells
		# us _ready() ran (it will be true or false definitively).
		if llm.is_ready() or llm.is_extension_available():
			return true
		# If _ready() has run but extension was not found, get_init_error()
		# will be non-empty — that's a definitive "not available".
		if llm.get_init_error() != "":
			return false
		await tree.process_frame
	return false


## Read the system prompt from disk.
static func _read_system_prompt() -> String:
	if not FileAccess.file_exists(SYSTEM_PROMPT_PATH):
		return ""
	var f := FileAccess.open(SYSTEM_PROMPT_PATH, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


## Send a prompt to the loaded LLM and return the generated text.
## Prints token-count progress every ~500 tokens while waiting.
func _generate(llm: Node, prompt: String, system_prompt: String) -> String:
	var handle = llm.generate_streaming({
		"prompt": prompt,
		"system_prompt": system_prompt,
		"max_tokens": 4096,
		"temperature": 0.0,
	})
	if handle == null:
		return ""
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var last_reported := 0
	while handle.get_status() == 0 or handle.get_status() == 1:
		var tokens_so_far: int = handle.get_tokens_generated()
		if tokens_so_far - last_reported >= 500:
			print("[eval]   ... %d tokens generated so far" % tokens_so_far)
			last_reported = tokens_so_far
		await tree.process_frame
	if handle.get_status() == 2:
		return handle.get_full_text()
	return ""


## Strip markdown code fences (```gdscript ... ```) from LLM output.
static func _strip_fences(text: String) -> String:
	var result := text.strip_edges()
	var re_open := RegEx.new()
	re_open.compile("^```(?:gdscript|gd)?\\s*\\n?")
	result = re_open.sub(result, "")
	var re_close := RegEx.new()
	re_close.compile("\\n?```\\s*$")
	result = re_close.sub(result, "")
	return result.strip_edges()


## Save compiled effect code to disk so the eval visualizer can load it later.
static func _save_effect_code(model_id: String, particle_prompt: String, code: String) -> void:
	var abs_dir := ProjectSettings.globalize_path("res://artifacts/eval/particle_effects")
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var slug := particle_prompt.to_lower().strip_edges().replace(" ", "_")
	var filename := "%s__%s.gd" % [model_id, slug]
	var filepath := "res://artifacts/eval/particle_effects".path_join(filename)
	var f := FileAccess.open(filepath, FileAccess.WRITE)
	if f:
		f.store_string(code)
		f.close()
		print("[eval] Saved effect code -> %s" % filepath)
	else:
		push_warning("[eval] Could not write effect code to %s" % filepath)


## Shared evaluation: load model, generate code, compile, instantiate, scene-load.
## Returns true if all checks pass.
func _run_particle_eval(model_id: String, particle_prompt: String) -> void:
	if _should_skip_model(model_id):
		print("[eval] Skipping %s (EVAL_MODEL_FILTER=%s)" % [model_id, OS.get_environment(ENV_MODEL_FILTER)])
		return

	var tag := "[eval %s | \"%s\"]" % [model_id, particle_prompt]
	var total_start := Time.get_ticks_msec()

	# ---- Step 1/7: Pre-flight checks --------------------------------------
	print("%s Step 1/7: Pre-flight checks ..." % tag)
	var llm := _get_llm()
	if llm == null:
		fail("LocalLLMService autoload not found -- is the LLM addon enabled?")
		return

	# When running via --script, autoload _ready() may not have fired yet.
	# Wait for LocalLLMService to finish initializing before checking.
	print("%s   Waiting for LocalLLMService to initialize ..." % tag)
	var ready := await _wait_for_llm_ready(llm)
	if not ready:
		if llm.get_init_error() != "":
			fail("LocalLLMService init error: %s" % llm.get_init_error())
		else:
			fail("LocalLLMService did not become ready within timeout")
		return

	if not llm.is_extension_available():
		fail("LLM native extension not available -- build the GDExtension first")
		return
	print("%s   Pre-flight OK (extension available)" % tag)

	# ---- Step 2/7: Load model ----------------------------------------------
	# Cap context length to avoid allocating enormous KV caches.
	# DeepSeek-Coder-V2's default 163840 context would need 43+ GB of RAM.
	# 8192 tokens gives enough room for system prompt + generated code.
	var settings = llm.get("_settings")
	if settings != null and settings.context_length <= 0:
		settings.context_length = 8192
		print("%s   Capped context_length to 8192 to save memory" % tag)

	print("%s Step 2/7: Loading model %s ..." % [tag, model_id])
	var load_start := Time.get_ticks_msec()
	var load_result: Dictionary = await llm.load_model(model_id)
	var load_ms := Time.get_ticks_msec() - load_start
	if not load_result.get("success", false):
		fail("Failed to load %s: %s" % [model_id, load_result.get("error", "unknown")])
		return
	print("%s   Model loaded in %.1fs" % [tag, load_ms / 1000.0])

	# ---- Step 3/7: Read system prompt --------------------------------------
	print("%s Step 3/7: Reading system prompt ..." % tag)
	var system_prompt := _read_system_prompt()
	assert_true(system_prompt.length() > 0,
		"System prompt file should exist and be non-empty")
	if system_prompt.is_empty():
		return
	print("%s   System prompt loaded (%d chars)" % [tag, system_prompt.length()])

	# ---- Step 4/7: Generate particle effect code ---------------------------
	print("%s Step 4/7: Generating code for \"%s\" ..." % [tag, particle_prompt])
	var gen_start := Time.get_ticks_msec()
	var raw_output := await _generate(llm, particle_prompt, system_prompt)
	var gen_ms := Time.get_ticks_msec() - gen_start
	assert_true(raw_output.length() > 0, "LLM should produce non-empty output")
	if raw_output.is_empty():
		return

	var code := _strip_fences(raw_output)
	assert_true(code.length() > 0,
		"Cleaned code should not be empty after stripping fences")
	if code.is_empty():
		return
	print("%s   Generated %d chars of GDScript in %.1fs" % [tag, code.length(), gen_ms / 1000.0])

	# ---- Step 5/7: Compile -------------------------------------------------
	print("%s Step 5/7: Compiling generated GDScript ..." % tag)
	var script := GDScript.new()
	script.source_code = code
	var compile_err := script.reload()
	assert_eq(OK, compile_err,
		"GDScript should compile without errors (got error code %d)" % compile_err)
	if compile_err != OK:
		print("%s   COMPILATION FAILED. Generated code:" % tag)
		print(code)
		return
	print("%s   Compilation: PASS" % tag)

	# Save compiled code for the eval visualizer grid
	_save_effect_code(model_id, particle_prompt, code)

	# ---- Step 6/7: Instantiate & verify ------------------------------------
	print("%s Step 6/7: Instantiating and verifying node ..." % tag)
	var instance = script.new()
	assert_true(instance != null, "Script should instantiate successfully")
	if instance == null:
		return

	var is_node := instance is Node
	assert_true(is_node, "Instance must be a Node")
	if not is_node:
		return

	var node: Node = instance as Node
	var is_2d := node is Node2D
	var is_3d := node is Node3D
	assert_true(is_2d or is_3d, "Instance must extend Node2D or Node3D")
	assert_true(node.has_method("play_at"), "Instance must have a play_at() method")
	print("%s   Node type: %s, has play_at(): %s" % [
		tag,
		"Node2D" if is_2d else ("Node3D" if is_3d else "other"),
		str(node.has_method("play_at"))
	])

	# ---- Step 7/7: Load as scene -------------------------------------------
	print("%s Step 7/7: Adding to scene tree (triggers _ready) ..." % tag)
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	tree.root.add_child(node)

	# Wait two frames for _ready() and any deferred calls to complete.
	await tree.process_frame
	await tree.process_frame

	assert_true(is_instance_valid(node),
		"Node should remain valid after _ready() executes")
	if not is_instance_valid(node):
		return

	var child_count := node.get_child_count()
	assert_true(child_count > 0,
		"Node should have created child nodes in _ready() (got %d)" % child_count)
	print("%s   Scene loading: PASS (node has %d children)" % [tag, child_count])

	# ---- Cleanup -----------------------------------------------------------
	node.queue_free()
	await tree.process_frame

	var total_ms := Time.get_ticks_msec() - total_start
	print("%s DONE -- all checks passed in %.1fs" % [tag, total_ms / 1000.0])


# ============================================================================
# Tests — DeepSeek Coder V2
# ============================================================================

## Generate a snowflake particle effect using deepseek-coder-v2 and verify the
## output compiles as valid GDScript and can be loaded into the scene tree.
func test_deepseek_snowflake_particle() -> void:
	await _run_particle_eval(MODEL_DEEPSEEK, PROMPT_SNOWFLAKE)


## Generate a sparkler effect using deepseek-coder-v2 and verify the output
## compiles as valid GDScript and can be loaded into the scene tree.
func test_deepseek_sparkler_particle() -> void:
	await _run_particle_eval(MODEL_DEEPSEEK, PROMPT_SPARKLER)


## Generate a fire burst effect using deepseek-coder-v2.
func test_deepseek_fire_burst_particle() -> void:
	await _run_particle_eval(MODEL_DEEPSEEK, PROMPT_FIRE_BURST)


## Generate a healing aura effect using deepseek-coder-v2.
func test_deepseek_healing_aura_particle() -> void:
	await _run_particle_eval(MODEL_DEEPSEEK, PROMPT_HEALING_AURA)


## Generate a lightning impact effect using deepseek-coder-v2.
func test_deepseek_lightning_particle() -> void:
	await _run_particle_eval(MODEL_DEEPSEEK, PROMPT_LIGHTNING)


## Generate a smoke cloud effect using deepseek-coder-v2.
func test_deepseek_smoke_cloud_particle() -> void:
	await _run_particle_eval(MODEL_DEEPSEEK, PROMPT_SMOKE_CLOUD)


## Generate a rain splash effect using deepseek-coder-v2.
func test_deepseek_rain_splash_particle() -> void:
	await _run_particle_eval(MODEL_DEEPSEEK, PROMPT_RAIN_SPLASH)


# ============================================================================
# Tests — Qwen 2.5 Coder
# ============================================================================

## Generate a snowflake particle effect using qwen2.5-coder-14b and verify the
## output compiles as valid GDScript and can be loaded into the scene tree.
func test_qwen_coder_snowflake_particle() -> void:
	await _run_particle_eval(MODEL_QWEN_CODER, PROMPT_SNOWFLAKE)


## Generate a sparkler effect using qwen2.5-coder-14b and verify the output
## compiles as valid GDScript and can be loaded into the scene tree.
func test_qwen_coder_sparkler_particle() -> void:
	await _run_particle_eval(MODEL_QWEN_CODER, PROMPT_SPARKLER)


## Generate a fire burst effect using qwen2.5-coder-14b.
func test_qwen_coder_fire_burst_particle() -> void:
	await _run_particle_eval(MODEL_QWEN_CODER, PROMPT_FIRE_BURST)


## Generate a healing aura effect using qwen2.5-coder-14b.
func test_qwen_coder_healing_aura_particle() -> void:
	await _run_particle_eval(MODEL_QWEN_CODER, PROMPT_HEALING_AURA)


## Generate a lightning impact effect using qwen2.5-coder-14b.
func test_qwen_coder_lightning_particle() -> void:
	await _run_particle_eval(MODEL_QWEN_CODER, PROMPT_LIGHTNING)


## Generate a smoke cloud effect using qwen2.5-coder-14b.
func test_qwen_coder_smoke_cloud_particle() -> void:
	await _run_particle_eval(MODEL_QWEN_CODER, PROMPT_SMOKE_CLOUD)


## Generate a rain splash effect using qwen2.5-coder-14b.
func test_qwen_coder_rain_splash_particle() -> void:
	await _run_particle_eval(MODEL_QWEN_CODER, PROMPT_RAIN_SPLASH)
