## LLMBenchmark - Utility for benchmarking LLM performance
##
## Provides methods to measure and report inference speed.
## Can be run from the LLMDebug scene or programmatically.
extends RefCounted
class_name LLMBenchmark

## Benchmark result structure
class BenchmarkResult:
	var model_id: String = ""
	var prompt_tokens: int = 0
	var generated_tokens: int = 0
	var total_time_seconds: float = 0.0
	var tokens_per_second: float = 0.0
	var time_to_first_token: float = 0.0
	var backend: String = ""
	var context_length: int = 0
	var n_threads: int = 0
	var n_gpu_layers: int = 0
	var success: bool = false
	var error: String = ""
	
	func to_dict() -> Dictionary:
		return {
			"model_id": model_id,
			"prompt_tokens": prompt_tokens,
			"generated_tokens": generated_tokens,
			"total_time_seconds": total_time_seconds,
			"tokens_per_second": tokens_per_second,
			"time_to_first_token": time_to_first_token,
			"backend": backend,
			"context_length": context_length,
			"n_threads": n_threads,
			"n_gpu_layers": n_gpu_layers,
			"success": success,
			"error": error
		}
	
	func to_string() -> String:
		if not success:
			return "Benchmark failed: " + error
		
		var lines: PackedStringArray = []
		lines.append("=== LLM Benchmark Results ===")
		lines.append("Model: %s" % model_id)
		lines.append("Backend: %s" % backend)
		lines.append("Threads: %d | GPU Layers: %d | Context: %d" % [n_threads, n_gpu_layers, context_length])
		lines.append("")
		lines.append("Prompt tokens: %d" % prompt_tokens)
		lines.append("Generated tokens: %d" % generated_tokens)
		lines.append("Time to first token: %.2f s" % time_to_first_token)
		lines.append("Total time: %.2f s" % total_time_seconds)
		lines.append("Speed: %.2f tokens/sec" % tokens_per_second)
		lines.append("============================")
		return "\n".join(lines)


## Standard benchmark prompt
const BENCHMARK_PROMPT = "Write a function that calculates the Fibonacci sequence recursively, then write an optimized version using dynamic programming. Include comments explaining the time complexity of each approach."

## Short prompt for quick testing
const QUICK_BENCHMARK_PROMPT = "Write a hello world function in Python with a docstring."


## Run a benchmark on the currently loaded model
static func run_benchmark(
	service: Node,  # LocalLLMService
	max_tokens: int = 100,
	use_quick_prompt: bool = false
) -> BenchmarkResult:
	var result = BenchmarkResult.new()
	
	# Check if model is loaded
	if not service.is_model_loaded():
		result.error = "No model loaded"
		return result
	
	# Get status info
	var status = service.get_status()
	result.model_id = status.get("model_id", "unknown")
	result.backend = status.get("backend", "unknown")
	result.context_length = status.get("context_length", 0)
	result.n_threads = status.get("n_threads", 0)
	result.n_gpu_layers = status.get("n_gpu_layers", 0)
	
	# Select prompt
	var prompt = QUICK_BENCHMARK_PROMPT if use_quick_prompt else BENCHMARK_PROMPT
	result.prompt_tokens = LLMContextManager.estimate_tokens(prompt)
	
	# Start timing
	var start_time = Time.get_ticks_usec()
	var first_token_time: float = 0.0
	var first_token_received = false
	
	# Generate
	var handle = service.generate_streaming({
		"prompt": prompt,
		"max_tokens": max_tokens,
		"temperature": 0.0,
		"stream": true
	})
	
	if handle == null:
		result.error = "Failed to start generation"
		return result
	
	# Track first token
	var token_callback = func(token: String):
		if not first_token_received:
			first_token_received = true
			first_token_time = (Time.get_ticks_usec() - start_time) / 1000000.0
	
	handle.token.connect(token_callback)
	
	# Wait for completion
	# Status constants: 0=PENDING, 1=RUNNING
	while handle.get_status() == 0 or handle.get_status() == 1:
		await Engine.get_main_loop().process_frame
	
	var end_time = Time.get_ticks_usec()
	
	# Collect results
	# Status: 2=COMPLETED
	if handle.get_status() == 2:
		result.success = true
		result.generated_tokens = handle.get_tokens_generated()
		result.total_time_seconds = (end_time - start_time) / 1000000.0
		result.time_to_first_token = first_token_time
		result.tokens_per_second = handle.get_tokens_per_second()
	else:
		result.error = handle.get_error_message()
		if result.error.is_empty():
			result.error = "Generation failed with status: " + str(handle.get_status())
	
	return result


## Run multiple benchmarks and average results
static func run_benchmark_suite(
	service: Node,
	iterations: int = 3,
	max_tokens: int = 100
) -> Dictionary:
	var results: Array[BenchmarkResult] = []
	
	for i in range(iterations):
		print("[Benchmark] Running iteration %d/%d..." % [i + 1, iterations])
		var result = await run_benchmark(service, max_tokens, true)
		results.append(result)
		
		if not result.success:
			return {
				"success": false,
				"error": "Iteration %d failed: %s" % [i + 1, result.error],
				"completed_iterations": i
			}
	
	# Calculate averages
	var total_tokens_per_sec: float = 0.0
	var total_time_to_first: float = 0.0
	var total_time: float = 0.0
	
	for r in results:
		total_tokens_per_sec += r.tokens_per_second
		total_time_to_first += r.time_to_first_token
		total_time += r.total_time_seconds
	
	var count = float(results.size())
	
	return {
		"success": true,
		"iterations": iterations,
		"model_id": results[0].model_id,
		"backend": results[0].backend,
		"avg_tokens_per_second": total_tokens_per_sec / count,
		"avg_time_to_first_token": total_time_to_first / count,
		"avg_total_time": total_time / count,
		"individual_results": results.map(func(r): return r.to_dict())
	}


## Format benchmark suite results for display
static func format_suite_results(suite_results: Dictionary) -> String:
	if not suite_results.get("success", false):
		return "Benchmark suite failed: " + suite_results.get("error", "Unknown error")
	
	var lines: PackedStringArray = []
	lines.append("=== Benchmark Suite Results ===")
	lines.append("Model: %s" % suite_results.model_id)
	lines.append("Backend: %s" % suite_results.backend)
	lines.append("Iterations: %d" % suite_results.iterations)
	lines.append("")
	lines.append("Average Results:")
	lines.append("  Tokens/sec: %.2f" % suite_results.avg_tokens_per_second)
	lines.append("  Time to first token: %.3f s" % suite_results.avg_time_to_first_token)
	lines.append("  Total generation time: %.2f s" % suite_results.avg_total_time)
	lines.append("===============================")
	
	return "\n".join(lines)


## Print system info for benchmark context
static func get_system_info() -> String:
	var lines: PackedStringArray = []
	lines.append("=== System Info ===")
	lines.append("OS: %s" % OS.get_name())
	lines.append("CPU Cores: %d" % OS.get_processor_count())
	lines.append("CPU Name: %s" % OS.get_processor_name())
	
	var mem = OS.get_memory_info()
	if mem.has("physical"):
		lines.append("RAM: %.1f GB" % (mem.physical / 1073741824.0))
	
	lines.append("===================")
	return "\n".join(lines)
