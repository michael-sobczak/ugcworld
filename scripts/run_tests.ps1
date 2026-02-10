param(
    [ValidateSet("unit", "integration", "eval", "all")]
    [string]$Mode = "all",

    # Optional: restrict eval tests to a single model (e.g. "deepseek-coder-v2")
    [string]$EvalModel = "",

    # Launch the visual particle effect grid after tests complete.
    # When used alone (-ShowResults without -Mode), skips test run and just
    # opens the viewer for results from a previous eval run.
    [switch]$ShowResults
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
        "C:\Users\micha\Documents\code\godot\Godot_v4.6-stable_win64_console.exe",
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

# The console Godot exe (Godot_v4.6-stable_win64_console.exe) is a console-
# subsystem binary, so PowerShell's call operator (&) blocks until it exits
# and stdout/stderr stream to the terminal normally.
#
# IMPORTANT: Do NOT capture Run-Godot's return value with $x = Run-Godot ...
# PowerShell functions emit ALL unassigned output to the pipeline, so the
# Godot stdout lines would be included alongside the exit code.  Instead,
# call Run-Godot without assignment and read $LASTEXITCODE afterwards.
function Run-Godot {
    param([string[]]$GodotArgs)
    & $godot @GodotArgs
}

# ---------------------------------------------------------------------------
# Decide whether to run tests.
# -ShowResults alone (no explicit -Mode) skips the test run and just opens
# the visualizer for results from a previous eval run.
# ---------------------------------------------------------------------------
$runTests = (-not $ShowResults) -or $PSBoundParameters.ContainsKey('Mode')
$testExit = 0

if ($runTests) {
    # Pass model filter to eval tests (empty string = run all models)
    $env:EVAL_MODEL_FILTER = $EvalModel
    if ($EvalModel) {
        Write-Host "[run_tests] Filtering eval tests to model: $EvalModel"
    }

    # Eval mode requires the native LLM extension -- build it if missing
    if ($Mode -eq "eval") {
        Ensure-LLMExtension
    }

    Run-Godot "--headless","--path",$projectDir,"--editor","--quit"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[run_tests] Editor import failed (exit code $LASTEXITCODE)" -ForegroundColor Red
        exit $LASTEXITCODE
    }

    $modeFlag = switch ($Mode) {
        "unit" { "--unit" }
        "integration" { "--integration" }
        "eval" { "--eval" }
        default { "--all" }
    }

    Write-Host "[run_tests] Starting test runner (mode=$Mode) ..."
    Run-Godot "--headless","--path",$projectDir, `
        "--script","res://addons/gdUnit4/bin/GdUnitRunner.gd","--", `
        $modeFlag, `
        "--junit=res://artifacts/test-results/junit.xml"
    $testExit = $LASTEXITCODE
    Write-Host "[run_tests] Test runner exited with code: $testExit"
}

# ---------------------------------------------------------------------------
# Visual results viewer — opens a Godot window (NOT headless) showing all
# generated particle effects in a labeled grid.
# ---------------------------------------------------------------------------
if ($ShowResults) {
    Write-Host ""
    Write-Host "[run_tests] Launching particle effect visualizer ..." -ForegroundColor Cyan
    Write-Host "[run_tests] Controls: ESC = quit, SPACE = replay effects" -ForegroundColor Cyan
    Write-Host ""
    Run-Godot "--path",$projectDir, `
        "--script","res://test/eval/particle_eval_visualizer.gd"
}

exit $testExit
