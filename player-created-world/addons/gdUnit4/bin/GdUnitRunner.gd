extends SceneTree

const DEFAULT_UNIT_DIR := "res://test/unit"
const DEFAULT_INTEGRATION_DIR := "res://test/integration"
const DEFAULT_EVAL_DIR := "res://test/eval"

var _results := []
var _current_suite_path := ""
var _current_test_name := ""
var _current_failures: Array[String] = []

func _initialize() -> void:
	# get_cmdline_user_args() returns only args after "--" (Godot strips the
	# separator).  get_cmdline_args() does NOT include them on all platforms.
	var args := _parse_args(OS.get_cmdline_user_args())
	var mode: String = args.get("mode", "all")
	var junit_path: String = args.get("junit", "")
	var start_time := Time.get_ticks_msec()

	var test_dirs: Array[String] = []
	if mode == "unit":
		test_dirs.append(DEFAULT_UNIT_DIR)
	elif mode == "integration":
		test_dirs.append(DEFAULT_INTEGRATION_DIR)
	elif mode == "eval":
		test_dirs.append(DEFAULT_EVAL_DIR)
	else:
		# "all" runs unit + integration but NOT eval (eval requires a local
		# LLM model and may take several minutes).
		test_dirs.append(DEFAULT_UNIT_DIR)
		test_dirs.append(DEFAULT_INTEGRATION_DIR)

	var test_files := _discover_test_files(test_dirs)
	for test_file in test_files:
		await _run_suite(test_file)

	var duration_ms := Time.get_ticks_msec() - start_time
	_print_summary(duration_ms)

	if junit_path != "":
		_write_junit(junit_path, duration_ms)

	var failures := _count_failures()
	quit(0 if failures == 0 else 1)

func _parse_args(raw_args: PackedStringArray) -> Dictionary:
	var args := {
		"mode": "all",
		"junit": ""
	}

	for entry in raw_args:
		if entry == "--unit":
			args["mode"] = "unit"
		elif entry == "--integration":
			args["mode"] = "integration"
		elif entry == "--all":
			args["mode"] = "all"
		elif entry == "--eval":
			args["mode"] = "eval"
		elif entry.begins_with("--junit="):
			args["junit"] = entry.substr("--junit=".length())
	return args

func _discover_test_files(dirs: Array[String]) -> Array[String]:
	var files: Array[String] = []
	for dir_path in dirs:
		files.append_array(_collect_gd_files(dir_path))
	return files

func _collect_gd_files(root_path: String) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(root_path)
	if dir == null:
		return result
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir():
			if not name.begins_with("."):
				result.append_array(_collect_gd_files("%s/%s" % [root_path, name]))
		else:
			if name.ends_with("_test.gd"):
				result.append("%s/%s" % [root_path, name])
		name = dir.get_next()
	dir.list_dir_end()
	return result

func _run_suite(path: String) -> void:
	var script := load(path)
	if script == null:
		_results.append(_result(path, "", 0, ["Failed to load test script."]))
		return
	var instance = script.new()
	if instance == null:
		_results.append(_result(path, "", 0, ["Failed to instantiate test script."]))
		return
	if not (instance is GdUnitTestSuite):
		return

	var methods: Array = instance.get_method_list()
	var test_methods: Array[String] = []
	for method in methods:
		var name: String = method.get("name", "")
		if name.begins_with("test_"):
			test_methods.append(name)
	test_methods.sort()

	if instance.has_method("before_all"):
		await instance.call("before_all")

	for test_name in test_methods:
		_current_suite_path = path
		_current_test_name = test_name
		_current_failures = []
		instance._set_reporter(self)
		if instance.has_method("before_each"):
			await instance.call("before_each")
		var test_start := Time.get_ticks_msec()
		await instance.call(test_name)
		var test_duration := (Time.get_ticks_msec() - test_start) / 1000.0
		if instance.has_method("after_each"):
			await instance.call("after_each")
		_results.append(_result(path, test_name, test_duration, _current_failures.duplicate()))

	if instance.has_method("after_all"):
		await instance.call("after_all")

func record_failure(message: String) -> void:
	_current_failures.append(message)

func _result(suite_path: String, test_name: String, duration: float, failures: Array[String]) -> Dictionary:
	return {
		"suite": suite_path,
		"name": test_name,
		"duration": duration,
		"failures": failures
	}

func _count_failures() -> int:
	var count := 0
	for result in _results:
		count += int((result.get("failures", []) as Array).size() > 0)
	return count

func _print_summary(duration_ms: int) -> void:
	var total := _results.size()
	var failures := _count_failures()
	print("[GdUnit4] Tests: %d, Failures: %d, Time: %.2fs" % [total, failures, duration_ms / 1000.0])
	for result in _results:
		var fails: Array = result.get("failures", [])
		if fails.size() > 0:
			print("[GdUnit4] FAIL %s::%s" % [result.get("suite", ""), result.get("name", "")])
			for failure in fails:
				print("[GdUnit4]   - %s" % failure)

func _write_junit(path: String, duration_ms: int) -> void:
	var total := _results.size()
	var failures := _count_failures()
	var xml := ""
	xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
	xml += "<testsuites tests=\"%d\" failures=\"%d\" time=\"%.3f\">\n" % [total, failures, duration_ms / 1000.0]
	var grouped := _group_by_suite()
	for suite_path in grouped.keys():
		var suite_results: Array = grouped[suite_path]
		var suite_failures := 0
		var suite_time := 0.0
		for result in suite_results:
			suite_time += float(result.get("duration", 0.0))
			if (result.get("failures", []) as Array).size() > 0:
				suite_failures += 1
		xml += "\t<testsuite name=\"%s\" tests=\"%d\" failures=\"%d\" time=\"%.3f\">\n" % [
			suite_path,
			suite_results.size(),
			suite_failures,
			suite_time
		]
		for result in suite_results:
			var test_name: String = result.get("name", "unknown")
			var test_time := float(result.get("duration", 0.0))
			xml += "\t\t<testcase classname=\"%s\" name=\"%s\" time=\"%.3f\">" % [suite_path, test_name, test_time]
			var fails: Array = result.get("failures", [])
			if fails.size() > 0:
				xml += "\n"
				for failure in fails:
					var message := _xml_escape(str(failure))
					xml += "\t\t\t<failure message=\"%s\">%s</failure>\n" % [message, message]
				xml += "\t\t</testcase>\n"
			else:
				xml += "</testcase>\n"
		xml += "\t</testsuite>\n"
	xml += "</testsuites>\n"

	var dir := DirAccess.open("res://")
	var abs_path := ProjectSettings.globalize_path(path)
	var base_dir := abs_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(base_dir)
	var file := FileAccess.open(abs_path, FileAccess.WRITE)
	if file != null:
		file.store_string(xml)
		file.close()

func _group_by_suite() -> Dictionary:
	var grouped := {}
	for result in _results:
		var suite: String = result.get("suite", "")
		if not grouped.has(suite):
			grouped[suite] = []
		grouped[suite].append(result)
	return grouped

func _xml_escape(value: String) -> String:
	return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
