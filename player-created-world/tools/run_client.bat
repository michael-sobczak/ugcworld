@echo off
REM Run the Godot client
REM Usage: run_client.bat [godot_path]

setlocal

set "SCRIPT_DIR=%~dp0"
set "PROJECT_DIR=%SCRIPT_DIR%.."

if "%~1"=="" (
    set "GODOT=godot"
) else (
    set "GODOT=%~1"
)

echo === Starting UGC World Client ===
echo Project: %PROJECT_DIR%
echo Godot: %GODOT%
echo.
echo Controls:
echo   C/Enter - Connect to server (auto-connects by default)
echo   1       - Create terrain
echo   2       - Dig terrain
echo   WASD    - Move camera
echo   RMB     - Toggle mouse look
echo.
echo Make sure the backend is running: cd ..\ugc_backend ^&^& python app.py
echo.

cd /d "%PROJECT_DIR%"
"%GODOT%" --main-scene "res://client/scenes/Main.tscn"
