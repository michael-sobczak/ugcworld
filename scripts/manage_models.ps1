<#
.SYNOPSIS
    AI Model Manager for UGC World (PowerShell wrapper)

.DESCRIPTION
    Downloads, manages, and integrates GGUF models into the Godot client.
    This is a wrapper script that calls the Python manage_models.py script.

.EXAMPLE
    .\manage_models.ps1                    # Interactive mode
    .\manage_models.ps1 --list             # List available models
    .\manage_models.ps1 --download all     # Download all models
    .\manage_models.ps1 --download coder   # Download Qwen2.5-Coder
    .\manage_models.ps1 --clean            # Remove all models
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonScript = Join-Path $ScriptDir "manage_models.py"

# Check for Python
$Python = $null
foreach ($cmd in @("python", "python3", "py")) {
    try {
        $version = & $cmd --version 2>&1
        if ($version -match "Python 3") {
            $Python = $cmd
            break
        }
    } catch {}
}

if (-not $Python) {
    Write-Host "ERROR: Python 3 not found. Please install Python 3.8 or later." -ForegroundColor Red
    exit 1
}

# Install requirements quietly (ignore any pip output)
$RequirementsFile = Join-Path $ScriptDir "requirements-models.txt"
if (Test-Path $RequirementsFile) {
    $null = & $Python -m pip install -q -r $RequirementsFile 2>&1
}

# Run the Python script with all arguments
& $Python $PythonScript @args
