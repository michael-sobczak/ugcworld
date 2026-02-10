# UGC World - Server Launcher (PowerShell)
# Run from repo root: .\launch_server.ps1

param(
    [int]$Port = 5000
)

Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "   UGC World Server" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ""

# Check we're in the right directory
if (-not (Test-Path "server_python/app.py")) {
    Write-Host "ERROR: Run this from the repo root!" -ForegroundColor Red
    exit 1
}

# Load environment
if (Test-Path "env.ps1") {
    Write-Host "[*] Loading env.ps1..." -ForegroundColor Cyan
    . .\env.ps1
}

# Set environment variables
$env:PORT = $Port
$env:HOST = "0.0.0.0"

if (-not $env:GODOT_PATH) {
    $env:GODOT_PATH = "C:\Users\micha\Documents\code\godot\Godot_v4.6-stable_win64_console.exe"
}
$env:GAME_SERVER_PATH = "$PWD\server_godot"

Write-Host "[*] GODOT_PATH: $env:GODOT_PATH" -ForegroundColor Cyan
Write-Host "[*] GAME_SERVER_PATH: $env:GAME_SERVER_PATH" -ForegroundColor Cyan
Write-Host ""

# Check Godot exists
if (-not (Test-Path $env:GODOT_PATH)) {
    Write-Host "[!] WARNING: Godot not found at $env:GODOT_PATH" -ForegroundColor Yellow
    Write-Host "    Game servers won't auto-spawn. Update GODOT_PATH in env.ps1" -ForegroundColor Yellow
    Write-Host ""
}

# Install Python dependencies
Write-Host "[*] Installing Python dependencies..." -ForegroundColor Cyan
Push-Location server_python
pip install -q -r requirements.txt 2>$null
Pop-Location

Write-Host ""
Write-Host "[+] Starting server on port $Port..." -ForegroundColor Green
Write-Host ""
Write-Host "Control Plane: http://127.0.0.1:$Port" -ForegroundColor White
Write-Host ""
Write-Host "TO RUN CLIENT:" -ForegroundColor Yellow
Write-Host "  1. Open player-created-world/ folder in Godot 4.6"
Write-Host "  2. Run Main.tscn"
Write-Host "  3. Press C to connect, then create/join a world"
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ""

# Start the server
Push-Location server_python
python app.py
Pop-Location
