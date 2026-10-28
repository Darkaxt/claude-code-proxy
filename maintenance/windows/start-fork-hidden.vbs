Option Explicit
Dim shell, fs, env, scratch, skill, supervisor, powerShell, result
If WScript.Arguments.Count <> 2 Then WScript.Quit 64
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
scratch = WScript.Arguments(0)
skill = WScript.Arguments(1)
If InStr(scratch, Chr(34)) > 0 Or InStr(skill, Chr(34)) > 0 Then WScript.Quit 64
If UCase(Left(scratch, 3)) <> "D:\" And UCase(Left(scratch, 3)) <> "E:\" Then WScript.Quit 64
If fs.GetDriveName(skill) = "" Then WScript.Quit 64
If Not fs.FolderExists(scratch) Or Not fs.FileExists(skill) Then WScript.Quit 66
supervisor = fs.BuildPath(fs.GetParentFolderName(WScript.ScriptFullName), "supervise-proxy.ps1")
If Not fs.FileExists(supervisor) Then WScript.Quit 66
Set env = shell.Environment("PROCESS")
env("TEMP") = scratch
env("TMP") = scratch
env("CCP_APPROACH_RECOVERY_SKILL_PATH") = skill
env("CCP_LOG_STDERR") = "1"
powerShell = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
' Wait for the actual supervisor exit; no deadline or detached duplicate worker.
result = shell.Run("""" & powerShell & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & supervisor & """", 0, True)
WScript.Quit result
