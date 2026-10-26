@echo off
rem Makes Windows start the Living Front bridge, hidden, every time you log in. It waits quietly
rem until Project Zomboid is running, loads the language model for as long as the game is open,
rem and frees the graphics card a minute after you quit. Run this once.
cd /d "%~dp0"
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "ENTRY=%STARTUP%\Living Front bridge.vbs"
echo ' Starts the Living Front bridge at login. Delete this file, or run remove_autostart.bat, to stop that.> "%ENTRY%"
echo CreateObject^("WScript.Shell"^).Run "wscript ""%~dp0lf_bridge_hidden.vbs""", 0, False>> "%ENTRY%"
wscript "%~dp0lf_bridge_hidden.vbs"
echo The Living Front bridge will now start by itself whenever you log in (and is running now).
echo Just play - talk to soldiers in game. Log: %~dp0lf_bridge.log
pause
