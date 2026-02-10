param(
    [ValidateSet("unit", "integration", "eval", "all")]
    [string]$Mode = "all",

    # Optional: restrict eval tests to a single model (e.g. "deepseek-coder-v2")
    [string]$EvalModel = ""
)

# Use "Continue" so stderr from native executables (Godot, llama.cpp) does
# not cause PowerShell to abort the script.  We check $LASTEXITCODE
# explicitly after each native call instead.
$ErrorActionPreference = "Continue"

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

# ---------------------------------------------------------------------------
# Ensure the LLM GDExtension is built (required for eval tests)
# ---------------------------------------------------------------------------
function Ensure-LLMExtension {
    $binDir = Join-Path $projectDir "addons\local_llm\bin"
    $editorDll = Join-Path $binDir "liblocal_llm.windows.editor.x86_64.dll"

    if (Test-Path $editorDll) {
        Write-Host "[run_tests] LLM GDExtension found: $($editorDll | Split-Path -Leaf)"
        return
    }

    Write-Host ""
    Write-Host "[run_tests] LLM GDExtension not found -- building automatically ..." -ForegroundColor Yellow
    Write-Host "[run_tests] (this is a one-time step; subsequent runs will skip it)" -ForegroundColor Yellow
    Write-Host ""

    $buildScript = Join-Path $PSScriptRoot "build_llm_win.ps1"
    if (-not (Test-Path $buildScript)) {
        Write-Host "[run_tests] ERROR: Build script not found: $buildScript" -ForegroundColor Red
        exit 1
    }

    & $buildScript
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[run_tests] ERROR: GDExtension build failed (exit code $LASTEXITCODE)." -ForegroundColor Red
        exit 1
    }

    if (-not (Test-Path $editorDll)) {
        Write-Host "[run_tests] ERROR: Build completed but DLL still missing: $editorDll" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "[run_tests] GDExtension build succeeded. Continuing with tests ..." -ForegroundColor Green
    Write-Host ""
}

$godot = Resolve-GodotBin
if (-not $godot) {
    Write-Host "ERROR: GODOT_BIN not set and no Godot binary found." -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

# Disable editor auto server/client to keep tests isolated
$env:UGCWORLD_AUTOSTART_SERVER = "0"
$env:UGCWORLD_AUTOCONNECT = "0"

# Pass model filter to eval tests (empty string = run all models)
$env:EVAL_MODEL_FILTER = $EvalModel
if ($EvalModel) {
    Write-Host "[run_tests] Filtering eval tests to model: $EvalModel"
}

# Eval mode requires the native LLM extension -- build it if missing
if ($Mode -eq "eval") {
    Ensure-LLMExtension
}

# NOTE: The non-console Godot exe (Godot_v4.6-stable_win64.exe) is a GUI
# subsystem binary.  PowerShell does NOT wait for GUI executables launched
# with & (call operator).  Wrapping in Start-Process -Wait ensures we block
# until Godot exits and capture its exit code properly.
function Run-Godot {
    param([string[]]$GodotArgs)
    $proc = Start-Process -FilePath $godot -ArgumentList $GodotArgs `
        -NoNewWindow -Wait -PassThru
    return $proc.ExitCode
}

$importExit = Run-Godot "--headless","--path",$projectDir,"--editor","--quit"
if ($importExit -ne 0) {
    Write-Host "[run_tests] Editor import failed (exit code $importExit)" -ForegroundColor Red
    exit $importExit
}

$modeFlag = switch ($Mode) {
    "unit" { "--unit" }
    "integration" { "--integration" }
    "eval" { "--eval" }
    default { "--all" }
}

Write-Host "[run_tests] Starting test runner (mode=$Mode) ..."
$testExit = Run-Godot "--headless","--path",$projectDir, `
    "--script","res://addons/gdUnit4/bin/GdUnitRunner.gd","--", `
    $modeFlag, `
    "--junit=res://artifacts/test-results/junit.xml"
Write-Host "[run_tests] Test runner exited with code: $testExit"
exit $testExit
