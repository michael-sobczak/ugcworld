# UGC World Environment Configuration (PowerShell)
# Source this file before running the server: . .\env.ps1

# Path to Godot 4.6 executables
# Console exe is preferred for CLI / headless use (PowerShell waits for it
# correctly and stdout streams to the terminal).
$env:GODOT_PATH = "C:\Users\micha\Documents\code\godot\Godot_v4.6-stable_win64_console.exe"
# Test runner uses GODOT_BIN; keep it in sync with GODOT_PATH
$env:GODOT_BIN = $env:GODOT_PATH

# Path to headless game server project
$env:GAME_SERVER_PATH = "$PWD\server_godot"

# Control plane settings
$env:PORT = "5000"
$env:HOST = "0.0.0.0"
$env:SECRET_KEY = "dev-secret-key-change-in-prod"

Write-Host "[env] Loaded environment variables" -ForegroundColor Green
Write-Host "  GODOT_PATH: $env:GODOT_PATH"
Write-Host "  GAME_SERVER_PATH: $env:GAME_SERVER_PATH"
