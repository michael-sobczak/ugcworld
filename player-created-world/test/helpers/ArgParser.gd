class_name ArgParser
extends RefCounted

static func parse(args: PackedStringArray) -> Dictionary:
	var results: Dictionary = {}
	var passthrough := false
	for entry in args:
		if entry == "--":
			passthrough = true
			continue
		if not passthrough:
			continue
		if entry.begins_with("--"):
			var parts := entry.substr(2).split("=", true, 2)
			if parts.size() == 1:
				results[parts[0]] = "true"
			else:
				results[parts[0]] = parts[1]
	return results

static func get_string(args: Dictionary, key: String, default_value: String = "") -> String:
	if args.has(key):
		return str(args[key])
	return default_value

static func get_int(args: Dictionary, key: String, default_value: int = 0) -> int:
	if args.has(key):
		return int(args[key])
	return default_value

static func get_float(args: Dictionary, key: String, default_value: float = 0.0) -> float:
	if args.has(key):
		return float(args[key])
	return default_value
