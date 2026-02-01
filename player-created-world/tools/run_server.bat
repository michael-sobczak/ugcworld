@echo off
REM Run the Python backend server
REM Usage: run_server.bat

setlocal

set "SCRIPT_DIR=%~dp0"
set "BACKEND_DIR=%SCRIPT_DIR%..\..\..\ugc_backend"

echo === Starting UGC Backend Server ===
echo Directory: %BACKEND_DIR%
echo.

cd /d "%BACKEND_DIR%"

REM Check if requirements are installed
python -c "import websockets" 2>nul
if errorlevel 1 (
    echo Installing requirements...
    pip install -r requirements.txt
)

python app.py
