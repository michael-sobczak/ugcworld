<#
.SYNOPSIS
    Build script for Local LLM GDExtension on Windows

.DESCRIPTION
    This script:
    1. Clones/updates llama.cpp and godot-cpp as submodules
    2. Builds llama.cpp as a static library
    3. Builds the GDExtension for Windows (Debug + Release)

.PARAMETER Target
    Build target: "debug", "release", or "all" (default: all)

.PARAMETER Clean
    Clean build directories before building

.PARAMETER CudaSupport
    Enable CUDA support (requires CUDA toolkit installed)

.EXAMPLE
    .\build_llm_win.ps1
    .\build_llm_win.ps1 -Target release
    .\build_llm_win.ps1 -Clean -CudaSupport
#>

param(
    [ValidateSet("debug", "release", "all")]
    [string]$Target = "all",
    
    [switch]$Clean,
    
    [switch]$CudaSupport
)

$ErrorActionPreference = "Stop"

# Paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$AddonDir = Join-Path $ProjectRoot "player-created-world\addons\local_llm"
$SrcDir = Join-Path $AddonDir "src"
$BinDir = Join-Path $AddonDir "bin"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Local LLM GDExtension Build Script" -ForegroundColor Cyan
Write-Host "  Platform: Windows" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Ensure we're in the source directory
Push-Location $SrcDir

try {
    # Step 1: Initialize submodules
    Write-Host "[1/5] Checking dependencies..." -ForegroundColor Yellow
    
    if (-not (Test-Path "llama.cpp")) {
        Write-Host "  Cloning llama.cpp..." -ForegroundColor Gray
        git clone --depth 1 https://github.com/ggerganov/llama.cpp.git
    } else {
        Write-Host "  llama.cpp already present" -ForegroundColor Gray
    }
    
    if (-not (Test-Path "godot-cpp")) {
        Write-Host "  Cloning godot-cpp..." -ForegroundColor Gray
        git clone --depth 1 --branch 4.4 https://github.com/godotengine/godot-cpp.git
    } else {
        Write-Host "  godot-cpp already present" -ForegroundColor Gray
    }
    
    # Step 2: Clean if requested
    if ($Clean) {
        Write-Host "[2/5] Cleaning build directories..." -ForegroundColor Yellow
        
        if (Test-Path "llama.cpp\build") {
            Write-Host "  Removing llama.cpp\build..." -ForegroundColor Gray
            Remove-Item -Recurse -Force "llama.cpp\build"
        }
        if (Test-Path "build") {
            Write-Host "  Removing build..." -ForegroundColor Gray
            Remove-Item -Recurse -Force "build"
        }
        if (Test-Path "godot-cpp\bin") {
            Write-Host "  Removing godot-cpp\bin..." -ForegroundColor Gray
            Remove-Item -Recurse -Force "godot-cpp\bin"
        }
        if (Test-Path $BinDir) {
            Write-Host "  Removing $BinDir..." -ForegroundColor Gray
            Remove-Item -Recurse -Force $BinDir
        }
        Write-Host "  Clean complete." -ForegroundColor Green
    } else {
        Write-Host "[2/5] Skipping clean (use -Clean to force)" -ForegroundColor Gray
    }
    
    # Ensure bin directory exists
    if (-not (Test-Path $BinDir)) {
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    }
    
    # Step 3: Build llama.cpp
    Write-Host "[3/5] Building llama.cpp..." -ForegroundColor Yellow
    
    $LlamaDir = Join-Path $SrcDir "llama.cpp"
    $LlamaBuildDir = Join-Path $LlamaDir "build"
    
    if (-not (Test-Path $LlamaBuildDir)) {
        New-Item -ItemType Directory -Path $LlamaBuildDir | Out-Null
    }
    
    Push-Location $LlamaBuildDir
    
    # Use static runtime (/MT, /MTd) to match godot-cpp
    # Generator expression for multi-config VS generator
    $CmakeArgs = @(
        "..",
        "-G", "Visual Studio 17 2022",
        "-A", "x64",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DLLAMA_BUILD_TESTS=OFF",
        "-DLLAMA_BUILD_EXAMPLES=OFF",
        "-DLLAMA_BUILD_SERVER=OFF",
        "-DGGML_NATIVE=OFF",
        "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW"
    )
    # Add runtime library setting with proper escaping for generator expression
    $CmakeArgs += '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded$<$<CONFIG:Debug>:Debug>'
    
    if ($CudaSupport) {
        Write-Host "  CUDA support enabled" -ForegroundColor Green
        $CmakeArgs += "-DGGML_CUDA=ON"
    }
    
    Write-Host "  Running CMake configure..." -ForegroundColor Gray
    Write-Host "  CMake args: $($CmakeArgs -join ' ')" -ForegroundColor DarkGray
    & cmake @CmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }
    
    if ($Target -eq "all" -or $Target -eq "release") {
        Write-Host "  Building Release..." -ForegroundColor Gray
        & cmake --build . --config Release --parallel
        if ($LASTEXITCODE -ne 0) { throw "llama.cpp Release build failed" }
    }
    
    if ($Target -eq "all" -or $Target -eq "debug") {
        Write-Host "  Building Debug..." -ForegroundColor Gray
        & cmake --build . --config Debug --parallel
        if ($LASTEXITCODE -ne 0) { throw "llama.cpp Debug build failed" }
    }
    
    Pop-Location
    
    # Step 4: Build godot-cpp
    Write-Host "[4/5] Building godot-cpp..." -ForegroundColor Yellow
    
    Push-Location "godot-cpp"
    
    if ($Target -eq "all" -or $Target -eq "release") {
        Write-Host "  Building Release..." -ForegroundColor Gray
        & "C:\Users\micha\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\Scripts\scons.exe" platform=windows target=template_release arch=x86_64 "-j$($env:NUMBER_OF_PROCESSORS)"
        if ($LASTEXITCODE -ne 0) { throw "godot-cpp Release build failed" }
    }
    
    if ($Target -eq "all" -or $Target -eq "debug") {
        Write-Host "  Building Debug..." -ForegroundColor Gray
        & "C:\Users\micha\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\Scripts\scons.exe" platform=windows target=template_debug arch=x86_64 "-j$($env:NUMBER_OF_PROCESSORS)"
        if ($LASTEXITCODE -ne 0) { throw "godot-cpp Debug build failed" }
    }
    
    Pop-Location
    
    # Step 5: Build the extension
    Write-Host "[5/5] Building Local LLM Extension..." -ForegroundColor Yellow
    
    if ($Target -eq "all" -or $Target -eq "release") {
        Write-Host "  Building Release..." -ForegroundColor Gray
        & "C:\Users\micha\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\Scripts\scons.exe" platform=windows target=template_release arch=x86_64 "-j$($env:NUMBER_OF_PROCESSORS)"
        if ($LASTEXITCODE -ne 0) { throw "Extension Release build failed" }
    }
    
    if ($Target -eq "all" -or $Target -eq "debug") {
        Write-Host "  Building Debug..." -ForegroundColor Gray
        & "C:\Users\micha\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\Scripts\scons.exe" platform=windows target=template_debug arch=x86_64 "-j$($env:NUMBER_OF_PROCESSORS)"
        if ($LASTEXITCODE -ne 0) { throw "Extension Debug build failed" }
    }
    
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Build Complete!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Output files in: $BinDir" -ForegroundColor Cyan
    Get-ChildItem $BinDir -Filter "*.dll" | ForEach-Object {
        Write-Host "  - $($_.Name)" -ForegroundColor Gray
    }
    
} catch {
    Write-Host ""
    Write-Host "BUILD FAILED: $_" -ForegroundColor Red
    exit 1
} finally {
    Pop-Location
}
