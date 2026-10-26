@echo off
rem Stops Windows starting the Living Front bridge at login.
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Living Front bridge.vbs" 2>nul
echo The bridge will no longer start at login. (A copy already running stops when you log out.)
pause
