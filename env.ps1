# UGC World Environment Configuration (PowerShell)
# Source this file before running the server: . .\env.ps1

# Path to Godot 4.6 executable (used to spawn headless game servers)
# UPDATE THIS to match your Godot installation
$env:GODOT_PATH = "C:\Users\micha\Downloads\Godot_v4.6-stable_win64.exe\Godot_v4.6-stable_win64.exe"

# Path to headless game server project
$env:GAME_SERVER_PATH = "$PWD\server_godot"

# Control plane settings
$env:PORT = "5000"
$env:HOST = "0.0.0.0"
$env:SECRET_KEY = "dev-secret-key-change-in-prod"

Write-Host "[env] Loaded environment variables" -ForegroundColor Green
Write-Host "  GODOT_PATH: $env:GODOT_PATH"
Write-Host "  GAME_SERVER_PATH: $env:GAME_SERVER_PATH"
