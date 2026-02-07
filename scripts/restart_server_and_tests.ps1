param(
    [ValidateSet("unit", "integration", "all")]
    [string]$Mode = "all",
    [int]$Port = 5000
)

$ErrorActionPreference = "Stop"

$rootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$serverDir = Join-Path $rootDir "server_python"

function Stop-ServerOnPort {
    param([int]$TargetPort)
    try {
        $conn = Get-NetTCPConnection -LocalPort $TargetPort -State Listen -ErrorAction SilentlyContinue
        if ($conn) {
            $pid = $conn.OwningProcess | Select-Object -First 1
            if ($pid) {
                Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
            }
        }
    } catch {
        # Ignore failures (e.g., older PowerShell or permissions).
    }
}

function Wait-ForPort {
    param([int]$TargetPort, [int]$Retries = 40, [int]$DelayMs = 500)
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect("127.0.0.1", $TargetPort)
            $client.Close()
            return $true
        } catch {
            Start-Sleep -Milliseconds $DelayMs
        }
    }
    return $false
}

Stop-ServerOnPort -TargetPort $Port

$env:PORT = $Port
$env:HOST = "0.0.0.0"

$serverProcess = Start-Process -FilePath "python" -ArgumentList "app.py" -WorkingDirectory $serverDir -PassThru
try {
    if (-not (Wait-ForPort -TargetPort $Port)) {
        throw "Server failed to start on port $Port"
    }

    & (Join-Path $rootDir "scripts\run_tests.ps1") -Mode $Mode
    exit $LASTEXITCODE
} finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
}
