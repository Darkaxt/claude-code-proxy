Option Explicit
Dim shell, fs, scriptPath, powerShell, mode, command, result
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
scriptPath = fs.BuildPath(fs.GetParentFolderName(WScript.ScriptFullName), "update-proxy.ps1")
powerShell = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
mode = "Check"
If WScript.Arguments.Count > 0 Then mode = WScript.Arguments(0)
command = """" & powerShell & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & scriptPath & """ -Mode " & mode
result = shell.Run(command, 0, True)
WScript.Quit result
