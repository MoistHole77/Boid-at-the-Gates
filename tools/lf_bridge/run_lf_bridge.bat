@echo off
rem Living Front bridge: Project Zomboid <-> a local language model.
rem You don't need to run this by hand if you ran install_autostart.bat once.
title Living Front bridge
cd /d "%~dp0"
rem 1) Chasm's own uv (it fetches a Python if there is none), 2) the Python launcher, 3) python.
if exist "%LOCALAPPDATA%\chasm\uv\uv.exe" (
    "%LOCALAPPDATA%\chasm\uv\uv.exe" run --no-project --python 3.12 lf_bridge.py %*
    goto :end
)
where py >nul 2>nul && ( py -3 lf_bridge.py %* & goto :end )
where python >nul 2>nul && ( python lf_bridge.py %* & goto :end )
echo Couldn't find Python or Chasm's uv. Install Chasm, or Python 3.9+ from python.org.
:end
if /i "%~1"=="--background" exit /b
pause
