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

- **Phi-3.5 Mini Instruct** (Q4_K_M, 2.4 GB) - Lightweight chat, fast responses
- **Qwen 2.5 Coder 14B** (Q4_K_M, 8.7 GB) - Default model for code generation
- **DeepSeek Coder V2 Lite** (Q4_K_M, 8.9 GB) - Precise code execution and validation
- **DeepSeek R1 Distill Qwen 14B** (Q4_K_M, 9.0 GB) - Chain-of-thought reasoning from DeepSeek R1
- **Qwen3 32B** (Q4_K_M, 19.8 GB) - Flagship model with thinking mode, strongest quality

## License

MIT License
