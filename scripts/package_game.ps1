<#
.SYNOPSIS
    Package the game with embedded LLM model(s)

.DESCRIPTION
    This script:
    1. Exports the Godot project
    2. Copies the GGUF model(s) to the export directory
    3. Creates a distributable archive

    RELEASE BUILD BEHAVIOR:
    When the game is packaged and run as a release build, it will automatically
    connect to the production server (wss://ugc-world-backend.fly.dev) on startup.
    This is detected using Godot's OS.has_feature("standalone") check in the client.
    In the editor, the connection dialog is shown instead.

.PARAMETER Platform
    Target platform: "windows" or "linux"

.PARAMETER ModelPath
    Path to the GGUF model file to include

.PARAMETER OutputDir
    Output directory for the packaged game

.EXAMPLE
    .\package_game.ps1 -Platform windows -ModelPath "models\qwen2.5-coder-14b-q4_k_m.gguf"
#>

param(
    [ValidateSet("windows", "linux")]
    [string]$Platform,
    
    [string]$ModelPath,
    
    [string]$OutputDir = "dist"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$GodotProjectDir = Join-Path $ProjectRoot "player-created-world"

# Show usage if required params are missing
if (-not $Platform -or -not $ModelPath) {
    Write-Host ""
    Write-Host "  Game Packaging Script" -ForegroundColor Cyan
    Write-Host "  =====================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  USAGE:" -ForegroundColor Yellow
    Write-Host "    .\package_game.ps1 -Platform <platform> -ModelPath <path>" -ForegroundColor White
    Write-Host ""
    Write-Host "  OPTIONS:" -ForegroundColor Yellow
    Write-Host "    -Platform    " -ForegroundColor Green -NoNewline
    Write-Host "windows | linux" -ForegroundColor White
    Write-Host "    -ModelPath   " -ForegroundColor Green -NoNewline
    Write-Host "Path to .gguf model file" -ForegroundColor White
    Write-Host "    -OutputDir   " -ForegroundColor Green -NoNewline
    Write-Host "(optional) Output directory, default: dist" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  EXAMPLES:" -ForegroundColor Yellow
    Write-Host "    .\package_game.ps1 -Platform windows -ModelPath player-created-world\models\qwen2.5-coder-14b-instruct-q4_k_m.gguf" -ForegroundColor DarkGray
    Write-Host "    .\package_game.ps1 -Platform linux -ModelPath .\models\my-model.gguf" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  NOTE: Release builds auto-connect to production server" -ForegroundColor Magenta
    Write-Host "        (wss://ugc-world-backend.fly.dev)" -ForegroundColor Magenta
    Write-Host ""
    exit 0
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Game Packaging Script" -ForegroundColor Cyan
Write-Host "  Platform: $Platform" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "NOTE: Release builds auto-connect to production server" -ForegroundColor Magenta
Write-Host "      (wss://ugc-world-backend.fly.dev)" -ForegroundColor Magenta
Write-Host ""

# Validate model file
if (-not (Test-Path $ModelPath)) {
    Write-Host "ERROR: Model file not found: $ModelPath" -ForegroundColor Red
    exit 1
}

$ModelSize = (Get-Item $ModelPath).Length / 1GB
Write-Host "Model: $ModelPath (${ModelSize:F2} GB)" -ForegroundColor Gray

# Create output directory
$OutputPath = Join-Path $ProjectRoot $OutputDir
$PlatformDir = Join-Path $OutputPath $Platform
if (-not (Test-Path $PlatformDir)) {
    New-Item -ItemType Directory -Path $PlatformDir -Force | Out-Null
}

# Create models directory in output
$ModelsOutputDir = Join-Path $PlatformDir "models"
if (-not (Test-Path $ModelsOutputDir)) {
    New-Item -ItemType Directory -Path $ModelsOutputDir -Force | Out-Null
}

Write-Host "[1/3] Copying model file..." -ForegroundColor Yellow
$ModelFileName = Split-Path -Leaf $ModelPath
$DestModelPath = Join-Path $ModelsOutputDir $ModelFileName
Copy-Item -Path $ModelPath -Destination $DestModelPath -Force

# Copy models.json
$ModelsJsonSrc = Join-Path $GodotProjectDir "models\models.json"
if (Test-Path $ModelsJsonSrc) {
    Copy-Item -Path $ModelsJsonSrc -Destination (Join-Path $ModelsOutputDir "models.json") -Force
}

Write-Host "[2/3] Exporting Godot project..." -ForegroundColor Yellow
Write-Host "  Note: Run 'godot --headless --export-release' manually if this fails" -ForegroundColor Gray

$ExportPreset = if ($Platform -eq "windows") { "Windows Desktop" } else { "Linux/X11" }
$ExecutableName = if ($Platform -eq "windows") { "PlayerCreatedWorld.exe" } else { "PlayerCreatedWorld.x86_64" }

# Try to export (this requires Godot to be in PATH)
try {
    Push-Location $GodotProjectDir
    & godot --headless --export-release "$ExportPreset" (Join-Path $PlatformDir $ExecutableName) 2>&1
    Pop-Location
} catch {
    Write-Host "  WARNING: Godot export failed. Export manually." -ForegroundColor Yellow
}

Write-Host "[3/3] Creating distribution archive..." -ForegroundColor Yellow

$ArchiveName = "PlayerCreatedWorld-$Platform.zip"
$ArchivePath = Join-Path $OutputPath $ArchiveName

if (Test-Path $ArchivePath) {
    Remove-Item $ArchivePath
}

Compress-Archive -Path "$PlatformDir\*" -DestinationPath $ArchivePath

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Packaging Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Output: $ArchivePath" -ForegroundColor Cyan

$ArchiveSize = (Get-Item $ArchivePath).Length / 1GB
Write-Host "Archive size: ${ArchiveSize:F2} GB" -ForegroundColor Gray
Write-Host ""
Write-Host "The packaged game will automatically connect to" -ForegroundColor Yellow
Write-Host "the production server on launch." -ForegroundColor Yellow