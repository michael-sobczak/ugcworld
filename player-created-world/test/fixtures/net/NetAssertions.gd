class_name NetAssertions
extends RefCounted

static func state_hash(state: Dictionary) -> String:
	var normalized := _normalize_value(state)
	var json := JSON.stringify(normalized)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(json.to_utf8_buffer())
	return ctx.finish().hex_encode()

static func _normalize_value(value):
	if value is Dictionary:
		var keys := value.keys()
		keys.sort()
		var result := {}
		for key in keys:
			result[key] = _normalize_value(value[key])
		return result
	if value is Array:
		var arr: Array = []
		for item in value:
			arr.append(_normalize_value(item))
		return arr
	return value
