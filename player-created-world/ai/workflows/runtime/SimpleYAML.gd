class_name SimpleYAML
extends RefCounted
## Minimal YAML-subset parser for workflow files.
##
## Supports: scalars, strings (quoted/unquoted), arrays (block & flow),
## mappings (block & flow), multi-line strings (| and >), and comments.
## Does NOT support anchors/aliases, tags, or multiple documents.


## Parse a YAML string and return a Variant (Dictionary, Array, String, etc.)
## Returns null on parse failure and pushes an error.
static func parse(text: String) -> Variant:
	if text.strip_edges().is_empty():
		return null
	var lines := text.split("\n")
	var ctx := {"lines": lines, "pos": 0}
	var result: Variant = _parse_value_block(ctx, -1)
	return result


## ---- Internal parsing ----

static func _current_line(ctx: Dictionary) -> String:
	if ctx["pos"] >= (ctx["lines"] as Array).size():
		return ""
	return ctx["lines"][ctx["pos"]]


static func _indent_of(line: String) -> int:
	var count := 0
	for ch in line:
		if ch == " " or ch == "\t":
			count += 1
		else:
			break
	return count


static func _strip_comment(line: String) -> String:
	## Remove inline comments (# not inside quotes)
	var in_single := false
	var in_double := false
	for i in range(line.length()):
		var ch := line[i]
		if ch == "'" and not in_double:
			in_single = not in_single
		elif ch == '"' and not in_single:
			in_double = not in_double
		elif ch == "#" and not in_single and not in_double:
			return line.substr(0, i)
	return line


static func _is_blank_or_comment(line: String) -> bool:
	var stripped := line.strip_edges()
	return stripped.is_empty() or stripped.begins_with("#")


static func _skip_blanks(ctx: Dictionary) -> void:
	var lines: Array = ctx["lines"]
	while ctx["pos"] < lines.size() and _is_blank_or_comment(lines[ctx["pos"]]):
		ctx["pos"] += 1


static func _parse_value_block(ctx: Dictionary, parent_indent: int) -> Variant:
	_skip_blanks(ctx)
	var lines: Array = ctx["lines"]
	if ctx["pos"] >= lines.size():
		return null

	var line: String = lines[ctx["pos"]]
	var indent := _indent_of(line)
	var stripped := _strip_comment(line).strip_edges()

	# Flow-style value on same line
	if stripped.begins_with("{"):
		return _parse_flow_mapping(stripped)
	if stripped.begins_with("["):
		return _parse_flow_array(stripped)

	# Block array (lines starting with "- ")
	if stripped.begins_with("- "):
		return _parse_block_array(ctx, indent)

	# Block mapping (lines with "key: value")
	if stripped.find(":") >= 0:
		return _parse_block_mapping(ctx, indent)

	# Plain scalar
	ctx["pos"] += 1
	return _parse_scalar(stripped)


static func _parse_block_mapping(ctx: Dictionary, base_indent: int) -> Dictionary:
	var result := {}
	var lines: Array = ctx["lines"]

	while ctx["pos"] < lines.size():
		_skip_blanks(ctx)
		if ctx["pos"] >= lines.size():
			break
		var line: String = lines[ctx["pos"]]
		var indent := _indent_of(line)
		if indent < base_indent:
			break
		if indent > base_indent and base_indent >= 0:
			break

		var stripped := _strip_comment(line).strip_edges()
		if stripped.is_empty():
			ctx["pos"] += 1
			continue

		# Handle list item in a mapping context (shouldn't happen at same indent)
		if stripped.begins_with("- "):
			break

		var colon_idx := stripped.find(":")
		if colon_idx < 0:
			ctx["pos"] += 1
			continue

		var key := stripped.substr(0, colon_idx).strip_edges()
		var after_colon := stripped.substr(colon_idx + 1).strip_edges()

		if after_colon.is_empty():
			# Value is on next line(s) as an indented block
			ctx["pos"] += 1
			_skip_blanks(ctx)
			if ctx["pos"] < lines.size():
				var next_line: String = lines[ctx["pos"]]
				var next_indent := _indent_of(next_line)
				var next_stripped := _strip_comment(next_line).strip_edges()
				if next_indent > indent:
					# Check for multi-line string indicators
					if after_colon == "|" or after_colon == ">":
						result[key] = _parse_multiline_string(ctx, next_indent, after_colon == "|")
					else:
						result[key] = _parse_value_block(ctx, next_indent)
				else:
					result[key] = null
			else:
				result[key] = null
		elif after_colon == "|" or after_colon == ">":
			ctx["pos"] += 1
			_skip_blanks(ctx)
			if ctx["pos"] < lines.size():
				var next_indent := _indent_of(lines[ctx["pos"]])
				result[key] = _parse_multiline_string(ctx, next_indent, after_colon == "|")
			else:
				result[key] = ""
		elif after_colon.begins_with("{"):
			result[key] = _parse_flow_mapping(after_colon)
			ctx["pos"] += 1
		elif after_colon.begins_with("["):
			result[key] = _parse_flow_array(after_colon)
			ctx["pos"] += 1
		else:
			result[key] = _parse_scalar(after_colon)
			ctx["pos"] += 1

	return result


static func _parse_block_array(ctx: Dictionary, base_indent: int) -> Array:
	var result := []
	var lines: Array = ctx["lines"]

	while ctx["pos"] < lines.size():
		_skip_blanks(ctx)
		if ctx["pos"] >= lines.size():
			break
		var line: String = lines[ctx["pos"]]
		var indent := _indent_of(line)
		if indent < base_indent:
			break
		if indent > base_indent:
			break

		var stripped := _strip_comment(line).strip_edges()
		if not stripped.begins_with("- "):
			break

		var item_text := stripped.substr(2).strip_edges()

		if item_text.is_empty():
			# Nested block under this list item
			ctx["pos"] += 1
			_skip_blanks(ctx)
			if ctx["pos"] < lines.size():
				var next_indent := _indent_of(lines[ctx["pos"]])
				if next_indent > indent:
					result.append(_parse_value_block(ctx, next_indent))
				else:
					result.append(null)
			else:
				result.append(null)
		elif item_text.begins_with("{"):
			result.append(_parse_flow_mapping(item_text))
			ctx["pos"] += 1
		elif item_text.begins_with("["):
			result.append(_parse_flow_array(item_text))
			ctx["pos"] += 1
		elif item_text.find(":") >= 0 and not item_text.begins_with('"') and not item_text.begins_with("'"):
			# Inline mapping as array element  (- key: val\n    key2: val2)
			# Parse the first key:val from item_text, then continue parsing
			# indented lines as part of this mapping
			var inline_dict := {}
			var ck := item_text.substr(0, item_text.find(":")).strip_edges()
			var cv := item_text.substr(item_text.find(":") + 1).strip_edges()
			if cv.begins_with("{"):
				inline_dict[ck] = _parse_flow_mapping(cv)
			elif cv.begins_with("["):
				inline_dict[ck] = _parse_flow_array(cv)
			elif cv.is_empty():
				ctx["pos"] += 1
				_skip_blanks(ctx)
				if ctx["pos"] < lines.size():
					var ni := _indent_of(lines[ctx["pos"]])
					if ni > indent + 2:
						inline_dict[ck] = _parse_value_block(ctx, ni)
					else:
						inline_dict[ck] = null
				else:
					inline_dict[ck] = null
				# Continue parsing sibling keys at indent+2
				var item_indent := indent + 2
				while ctx["pos"] < lines.size():
					_skip_blanks(ctx)
					if ctx["pos"] >= lines.size():
						break
					var nl: String = lines[ctx["pos"]]
					var ni2 := _indent_of(nl)
					if ni2 < item_indent:
						break
					if ni2 > item_indent:
						break
					var ns := _strip_comment(nl).strip_edges()
					if ns.begins_with("- "):
						break
					var ci := ns.find(":")
					if ci < 0:
						ctx["pos"] += 1
						continue
					var k2 := ns.substr(0, ci).strip_edges()
					var v2 := ns.substr(ci + 1).strip_edges()
					if v2.is_empty():
						ctx["pos"] += 1
						_skip_blanks(ctx)
						if ctx["pos"] < lines.size() and _indent_of(lines[ctx["pos"]]) > ni2:
							inline_dict[k2] = _parse_value_block(ctx, _indent_of(lines[ctx["pos"]]))
						else:
							inline_dict[k2] = null
					elif v2.begins_with("{"):
						inline_dict[k2] = _parse_flow_mapping(v2)
						ctx["pos"] += 1
					elif v2.begins_with("["):
						inline_dict[k2] = _parse_flow_array(v2)
						ctx["pos"] += 1
					else:
						inline_dict[k2] = _parse_scalar(v2)
						ctx["pos"] += 1
				result.append(inline_dict)
				continue
			else:
				inline_dict[ck] = _parse_scalar(cv)
			ctx["pos"] += 1
			# Parse remaining keys at indent + 2
			var item_indent := indent + 2
			while ctx["pos"] < lines.size():
				_skip_blanks(ctx)
				if ctx["pos"] >= lines.size():
					break
				var nl: String = lines[ctx["pos"]]
				var ni := _indent_of(nl)
				if ni < item_indent:
					break
				if ni > item_indent:
					break
				var ns := _strip_comment(nl).strip_edges()
				if ns.begins_with("- "):
					break
				var ci := ns.find(":")
				if ci < 0:
					ctx["pos"] += 1
					continue
				var k2 := ns.substr(0, ci).strip_edges()
				var v2 := ns.substr(ci + 1).strip_edges()
				if v2.is_empty():
					ctx["pos"] += 1
					_skip_blanks(ctx)
					if ctx["pos"] < lines.size() and _indent_of(lines[ctx["pos"]]) > ni:
						inline_dict[k2] = _parse_value_block(ctx, _indent_of(lines[ctx["pos"]]))
					else:
						inline_dict[k2] = null
				elif v2.begins_with("{"):
					inline_dict[k2] = _parse_flow_mapping(v2)
					ctx["pos"] += 1
				elif v2.begins_with("["):
					inline_dict[k2] = _parse_flow_array(v2)
					ctx["pos"] += 1
				else:
					inline_dict[k2] = _parse_scalar(v2)
					ctx["pos"] += 1
			result.append(inline_dict)
			continue
		else:
			result.append(_parse_scalar(item_text))
			ctx["pos"] += 1

	return result


static func _parse_multiline_string(ctx: Dictionary, base_indent: int, literal: bool) -> String:
	var lines: Array = ctx["lines"]
	var parts: PackedStringArray = []
	while ctx["pos"] < lines.size():
		var line: String = lines[ctx["pos"]]
		if not _is_blank_or_comment(line):
			var indent := _indent_of(line)
			if indent < base_indent:
				break
			parts.append(line.substr(base_indent))
		else:
			parts.append("")
		ctx["pos"] += 1
	if literal:
		return "\n".join(parts).strip_edges()
	else:
		return " ".join(parts).strip_edges()


static func _parse_flow_mapping(text: String) -> Dictionary:
	var result := {}
	var inner := text.strip_edges()
	if inner.begins_with("{"):
		inner = inner.substr(1)
	if inner.ends_with("}"):
		inner = inner.substr(0, inner.length() - 1)
	inner = inner.strip_edges()
	if inner.is_empty():
		return result

	for pair in _split_flow(inner):
		var p := pair.strip_edges()
		var ci := p.find(":")
		if ci < 0:
			continue
		var k := p.substr(0, ci).strip_edges()
		var v := p.substr(ci + 1).strip_edges()
		result[k] = _parse_scalar(v)
	return result


static func _parse_flow_array(text: String) -> Array:
	var result := []
	var inner := text.strip_edges()
	if inner.begins_with("["):
		inner = inner.substr(1)
	if inner.ends_with("]"):
		inner = inner.substr(0, inner.length() - 1)
	inner = inner.strip_edges()
	if inner.is_empty():
		return result

	for item in _split_flow(inner):
		result.append(_parse_scalar(item.strip_edges()))
	return result


## Split a flow-style string by commas, respecting nested braces/brackets/quotes.
static func _split_flow(text: String) -> PackedStringArray:
	var parts: PackedStringArray = []
	var depth := 0
	var in_quote := false
	var quote_char := ""
	var current := ""
	for i in range(text.length()):
		var ch := text[i]
		if in_quote:
			current += ch
			if ch == quote_char:
				in_quote = false
			continue
		if ch == '"' or ch == "'":
			in_quote = true
			quote_char = ch
			current += ch
			continue
		if ch == "{" or ch == "[":
			depth += 1
			current += ch
		elif ch == "}" or ch == "]":
			depth -= 1
			current += ch
		elif ch == "," and depth == 0:
			parts.append(current)
			current = ""
		else:
			current += ch
	if not current.strip_edges().is_empty():
		parts.append(current)
	return parts


## Parse a scalar value string into the appropriate type.
static func _parse_scalar(text: String) -> Variant:
	var s := text.strip_edges()
	if s.is_empty():
		return ""

	# Quoted strings
	if (s.begins_with('"') and s.ends_with('"')) or (s.begins_with("'") and s.ends_with("'")):
		return s.substr(1, s.length() - 2)

	# Boolean
	var lower := s.to_lower()
	if lower == "true" or lower == "yes":
		return true
	if lower == "false" or lower == "no":
		return false

	# Null
	if lower == "null" or lower == "~":
		return null

	# Integer
	if s.is_valid_int():
		return s.to_int()

	# Float
	if s.is_valid_float():
		return s.to_float()

	# Plain string
	return s
