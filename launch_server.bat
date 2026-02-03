@echo off
REM UGC World - Server Launcher
REM Starts the Control Plane server
REM Run from repo root: launch_server.bat

echo.
echo ========================================
echo    UGC World Server
echo ========================================
echo.

REM Set environment
set GODOT_PATH=C:\Users\micha\Downloads\Godot_v4.6-stable_win64.exe\Godot_v4.6-stable_win64.exe
set GAME_SERVER_PATH=..\server_godot
set PORT=5000

REM Check we're in the right place
if not exist "server_python\app.py" (
    echo ERROR: Run this from the repo root!
    pause
    exit /b 1
)

REM Install deps
echo Installing dependencies...
cd server_python
pip install -q -r requirements.txt 2>nul

echo.
echo Starting server...
echo.
echo Control Plane: http://127.0.0.1:5000
echo.
echo The server will auto-spawn game servers when clients join.
echo.
echo TO RUN CLIENT:
echo   1. Open player-created-world/ folder in Godot 4.6
echo   2. Run Main.tscn
echo   3. Press C to connect, then create/join a world
echo.
echo ========================================
echo.

python app.py

pause
