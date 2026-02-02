# Local LLM Plugin for Godot

Fully embedded, offline LLM inference for Godot games using llama.cpp.

## Features

- **Fully Offline** - No API keys, no network calls
- **Self-Contained** - Model ships with game, no separate downloads
- **Non-Blocking** - Async generation with streaming tokens
- **Game-Ready** - Designed for real-time game integration
- **Extensible** - Add models without code changes

## Quick Start

1. Enable the plugin in Project -> Project Settings -> Plugins
2. Place your GGUF model in res://models/
3. Update res://models/models.json with model info
4. Use LocalLLMService autoload in your scripts:

```gdscript
var result = await LocalLLMService.generate("Write hello world in GDScript")
print(result.text)
```

## Streaming Generation

```gdscript
var handle = LocalLLMService.generate_streaming({
    "prompt": "Explain how spells work",
    "max_tokens": 256,
    "temperature": 0.7
})

handle.token.connect(func(chunk): print(chunk))
handle.completed.connect(func(text): print("Done!"))
```

## Building

See scripts/build_llm_win.ps1 or scripts/build_llm_linux.sh.

## Documentation

Full documentation: docs/LOCAL_LLM.md

## Current Models

- Qwen 2.5 Coder 14B (Q4_K_M) - Default model for code generation
- Qwen 2.5 Coder 14B (Q5_K_M) - Higher quality variant

## License

MIT License
