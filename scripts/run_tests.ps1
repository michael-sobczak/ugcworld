param(
    [ValidateSet("unit", "integration", "all")]
    [string]$Mode = "all"
)

$ErrorActionPreference = "Stop"

$rootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$projectDir = Join-Path $rootDir "player-created-world"
$artifactsDir = Join-Path $rootDir "artifacts"
$logDir = Join-Path $artifactsDir "test-logs"
$resultsDir = Join-Path $artifactsDir "test-results"

if (Test-Path (Join-Path $rootDir "env.ps1")) {
    . (Join-Path $rootDir "env.ps1") | Out-Null
}

function Resolve-GodotBin {
    if ($env:GODOT_BIN -and (Test-Path $env:GODOT_BIN)) {
        return $env:GODOT_BIN
    }
    if ($env:GODOT_PATH -and (Test-Path $env:GODOT_PATH)) {
        return $env:GODOT_PATH
    }
    $cmd = Get-Command godot4 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }

    $fallbacks = @(
        (Join-Path $rootDir "godot\Godot_v4.6-stable_win64_console.exe"),
        "C:\Godot\Godot_v4.6-stable_win64_console.exe",
        "C:\Godot\Godot_v4.6-stable_win64.exe"
    )
    foreach ($path in $fallbacks) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

$godot = Resolve-GodotBin
if (-not $godot) {
    Write-Error "GODOT_BIN not set and no Godot binary found."
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

& $godot --headless --path $projectDir --editor --quit
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$modeFlag = switch ($Mode) {
    "unit" { "--unit" }
    "integration" { "--integration" }
    default { "--all" }
}

& $godot --headless --path $projectDir `
    --script "res://addons/gdUnit4/bin/GdUnitRunner.gd" -- `
    $modeFlag `
    "--junit=res://artifacts/test-results/junit.xml"
exit $LASTEXITCODE
