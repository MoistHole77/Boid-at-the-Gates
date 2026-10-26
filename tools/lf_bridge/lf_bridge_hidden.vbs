' Living Front bridge, started with no window (used by install_autostart.bat).
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "cmd /c """ & here & "\run_lf_bridge.bat"" --background", 0, False
