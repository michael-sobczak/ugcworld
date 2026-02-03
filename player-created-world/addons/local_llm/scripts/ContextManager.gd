## ContextManager - Utility for managing context windows
##
## Helps chunk and manage code/text to fit within LLM context limits.
## Provides utilities for estimating token counts and splitting content.
extends RefCounted
class_name LLMContextManager

## Approximate characters per token (rough estimate)
## This varies by model and content type
const CHARS_PER_TOKEN_ESTIMATE = 4.0

## Default context budget (leave room for response)
const DEFAULT_RESPONSE_RESERVE = 1024


## Estimate token count for text
## This is a rough estimate - actual tokenization varies by model
static func estimate_tokens(text: String) -> int:
	if text.is_empty():
		return 0
	return max(1, int(ceil(text.length() / CHARS_PER_TOKEN_ESTIMATE)))


## Check if text fits within a token budget
static func fits_in_context(text: String, max_tokens: int) -> bool:
	return estimate_tokens(text) <= max_tokens


## Split text into chunks that fit within token limit
## Tries to split on natural boundaries (newlines, sentences)
static func chunk_text(text: String, max_tokens_per_chunk: int) -> PackedStringArray:
	var chunks: PackedStringArray = []
	
	if text.is_empty():
		return chunks
	
	var max_chars = int(max_tokens_per_chunk * CHARS_PER_TOKEN_ESTIMATE)
	
	# If it fits in one chunk, return as-is
	if text.length() <= max_chars:
		chunks.append(text)
		return chunks
	
	# Try to split on paragraph boundaries first
	var paragraphs = text.split("\n\n")
	var current_chunk = ""
	
	for para in paragraphs:
		var para_with_sep = para + "\n\n"
		
		if current_chunk.length() + para_with_sep.length() <= max_chars:
			current_chunk += para_with_sep
		else:
			# Current chunk is full
			if not current_chunk.is_empty():
				chunks.append(current_chunk.strip_edges())
			
			# Check if paragraph itself needs splitting
			if para.length() > max_chars:
				var para_chunks = _split_paragraph(para, max_chars)
				for pc in para_chunks:
					chunks.append(pc)
				current_chunk = ""
			else:
				current_chunk = para_with_sep
	
	if not current_chunk.strip_edges().is_empty():
		chunks.append(current_chunk.strip_edges())
	
	return chunks


## Split a single paragraph into smaller pieces
static func _split_paragraph(para: String, max_chars: int) -> PackedStringArray:
	var chunks: PackedStringArray = []
	
	# Try splitting on sentences
	var sentences = para.split(". ")
	var current = ""
	
	for sent in sentences:
		var sent_with_period = sent + ". "
		
		if current.length() + sent_with_period.length() <= max_chars:
			current += sent_with_period
		else:
			if not current.is_empty():
				chunks.append(current.strip_edges())
			
			# Force split if sentence is too long
			if sent.length() > max_chars:
				var forced = _force_split(sent, max_chars)
				for f in forced:
					chunks.append(f)
				current = ""
			else:
				current = sent_with_period
	
	if not current.strip_edges().is_empty():
		chunks.append(current.strip_edges())
	
	return chunks


## Force split text at max_chars boundary
static func _force_split(text: String, max_chars: int) -> PackedStringArray:
	var chunks: PackedStringArray = []
	var pos = 0
	
	while pos < text.length():
		var end = min(pos + max_chars, text.length())
		
		# Try to break at word boundary
		if end < text.length():
			var space_pos = text.rfind(" ", end)
			if space_pos > pos:
				end = space_pos
		
		chunks.append(text.substr(pos, end - pos).strip_edges())
		pos = end
		
		# Skip whitespace
		while pos < text.length() and text[pos] == " ":
			pos += 1
	
	return chunks


## Chunk code files for context inclusion
## Preserves function/class boundaries where possible
static func chunk_code(code: String, max_tokens_per_chunk: int, language: String = "") -> Array[Dictionary]:
	var chunks: Array[Dictionary] = []
	var max_chars = int(max_tokens_per_chunk * CHARS_PER_TOKEN_ESTIMATE)
	
	# Split by lines for code
	var lines = code.split("\n")
	var current_chunk = ""
	var chunk_start_line = 1
	var current_line = 1
	
	for line in lines:
		var line_with_newline = line + "\n"
		
		if current_chunk.length() + line_with_newline.length() <= max_chars:
			current_chunk += line_with_newline
		else:
			if not current_chunk.is_empty():
				chunks.append({
					"content": current_chunk,
					"start_line": chunk_start_line,
					"end_line": current_line - 1,
					"language": language,
					"tokens_estimate": estimate_tokens(current_chunk)
				})
			
			current_chunk = line_with_newline
			chunk_start_line = current_line
		
		current_line += 1
	
	if not current_chunk.is_empty():
		chunks.append({
			"content": current_chunk,
			"start_line": chunk_start_line,
			"end_line": current_line - 1,
			"language": language,
			"tokens_estimate": estimate_tokens(current_chunk)
		})
	
	return chunks


## Build a context window from multiple sources
## Returns a formatted string and metadata about what was included
static func build_context(
	sources: Array[Dictionary],  # [{type, content, name, priority}]
	max_tokens: int,
	response_reserve: int = DEFAULT_RESPONSE_RESERVE
) -> Dictionary:
	var available_tokens = max_tokens - response_reserve
	var result = {
		"context": "",
		"included_sources": [],
		"tokens_used": 0,
		"tokens_available": available_tokens
	}
	
	# Sort by priority (higher = included first)
	sources.sort_custom(func(a, b): return a.get("priority", 0) > b.get("priority", 0))
	
	for source in sources:
		var content = source.get("content", "")
		var tokens = estimate_tokens(content)
		
		if result.tokens_used + tokens <= available_tokens:
			# Format based on type
			var formatted = _format_source(source)
			result.context += formatted + "\n\n"
			result.tokens_used += tokens
			result.included_sources.append({
				"name": source.get("name", "unnamed"),
				"type": source.get("type", "text"),
				"tokens": tokens
			})
	
	result.context = result.context.strip_edges()
	return result


## Format a source for context inclusion
static func _format_source(source: Dictionary) -> String:
	var content = source.get("content", "")
	var source_name = source.get("name", "")
	var source_type = source.get("type", "text")
	
	match source_type:
		"code":
			var lang = source.get("language", "")
			if not source_name.is_empty():
				return "### %s\n```%s\n%s\n```" % [source_name, lang, content]
			else:
				return "```%s\n%s\n```" % [lang, content]
		"file":
			return "### File: %s\n%s" % [source_name, content]
		"instruction":
			return "**%s**\n%s" % [source_name, content] if not source_name.is_empty() else content
		_:
			return content


## Create a context summary showing what's included
static func summarize_context(context_result: Dictionary) -> String:
	var lines: PackedStringArray = []
	lines.append("Context Summary:")
	lines.append("  Tokens used: %d / %d" % [
		context_result.tokens_used,
		context_result.tokens_available
	])
	lines.append("  Sources included: %d" % context_result.included_sources.size())
	
	for source in context_result.included_sources:
		lines.append("    - %s (%s): %d tokens" % [
			source.name,
			source.type,
			source.tokens
		])
	
	return "\n".join(lines)
