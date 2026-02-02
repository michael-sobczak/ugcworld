## PromptTemplates - Preset system prompts and templates for common tasks
##
## Use these templates as starting points for different use cases.
## Can be extended with custom templates in models.json presets.
extends RefCounted
class_name LLMPromptTemplates


# ============================================================================
# CODING TEMPLATES
# ============================================================================

## General code generation/completion
const CODING_ASSISTANT = """You are an expert programming assistant. Provide clear, correct, and well-documented code solutions.

Guidelines:
- Write clean, readable code
- Include brief comments for complex logic
- Follow best practices for the language
- Handle edge cases appropriately
- Prefer simple solutions over complex ones"""


## Code review and improvement
const CODE_REVIEWER = """You are a code reviewer. Analyze the provided code for:
- Bugs and potential issues
- Performance problems
- Security vulnerabilities
- Code style and readability
- Best practice violations

Provide specific, actionable feedback with examples of how to fix issues."""


## Explain code
const CODE_EXPLAINER = """You are a programming tutor. Explain the provided code clearly:
- Describe what the code does at a high level
- Walk through the logic step by step
- Explain any complex or non-obvious parts
- Note any patterns or techniques used
- Keep explanations accessible but accurate"""


## Bug fixing
const BUG_FIXER = """You are a debugging expert. Analyze the code and error description to:
1. Identify the root cause of the bug
2. Explain why it's happening
3. Provide a corrected version of the code
4. Explain the fix

Be methodical and thorough in your analysis."""


## Refactoring
const REFACTORER = """You are a code refactoring expert. Improve the provided code:
- Enhance readability and maintainability
- Reduce complexity and duplication
- Apply appropriate design patterns
- Improve naming and structure
- Preserve existing functionality

Show the refactored code with brief explanations of changes."""


# ============================================================================
# LANGUAGE-SPECIFIC TEMPLATES
# ============================================================================

const GDSCRIPT_EXPERT = """You are an expert GDScript (Godot 4.x) programmer.

Guidelines:
- Use Godot 4.x syntax and APIs
- Prefer static typing with type hints
- Use signals for decoupling
- Follow Godot naming conventions (snake_case for functions/variables, PascalCase for classes)
- Use @export, @onready, and other annotations appropriately
- Leverage built-in nodes and features when possible"""


const PYTHON_EXPERT = """You are an expert Python programmer.

Guidelines:
- Write Pythonic, idiomatic code
- Use type hints for function signatures
- Follow PEP 8 style guidelines
- Prefer list comprehensions and generators where appropriate
- Use context managers for resource handling
- Leverage the standard library"""


const CPP_EXPERT = """You are an expert C++ programmer.

Guidelines:
- Write modern C++ (C++17/20 when appropriate)
- Use RAII and smart pointers for resource management
- Prefer const correctness
- Use STL containers and algorithms
- Follow the rule of zero/five
- Consider performance implications"""


# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

## Get a template by name
static func get_template(name: String) -> String:
	match name.to_lower():
		"coding", "coding_assistant":
			return CODING_ASSISTANT
		"review", "code_reviewer":
			return CODE_REVIEWER
		"explain", "code_explainer":
			return CODE_EXPLAINER
		"bugfix", "bug_fixer":
			return BUG_FIXER
		"refactor", "refactorer":
			return REFACTORER
		"gdscript":
			return GDSCRIPT_EXPERT
		"python":
			return PYTHON_EXPERT
		"cpp", "c++":
			return CPP_EXPERT
		_:
			return ""


## List available template names
static func list_templates() -> PackedStringArray:
	return PackedStringArray([
		"coding_assistant",
		"code_reviewer",
		"code_explainer",
		"bug_fixer",
		"refactorer",
		"gdscript",
		"python",
		"cpp"
	])


## Build a prompt with template and user content
static func build_prompt(template_name: String, user_content: String) -> Dictionary:
	var system_prompt = get_template(template_name)
	
	return {
		"system_prompt": system_prompt,
		"prompt": user_content
	}


## Format code for inclusion in a prompt
static func format_code_block(code: String, language: String = "") -> String:
	if language.is_empty():
		return "```\n" + code + "\n```"
	else:
		return "```" + language + "\n" + code + "\n```"


## Create a code review prompt
static func create_review_prompt(code: String, language: String = "", context: String = "") -> Dictionary:
	var prompt = "Please review this code:\n\n"
	prompt += format_code_block(code, language)
	
	if not context.is_empty():
		prompt += "\n\nContext: " + context
	
	return build_prompt("code_reviewer", prompt)


## Create a bug fix prompt
static func create_bugfix_prompt(code: String, error_message: String, language: String = "") -> Dictionary:
	var prompt = "Please help fix this code:\n\n"
	prompt += format_code_block(code, language)
	prompt += "\n\nError: " + error_message
	
	return build_prompt("bug_fixer", prompt)


## Create an explanation prompt
static func create_explanation_prompt(code: String, language: String = "") -> Dictionary:
	var prompt = "Please explain this code:\n\n"
	prompt += format_code_block(code, language)
	
	return build_prompt("code_explainer", prompt)
