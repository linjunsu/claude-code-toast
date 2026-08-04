' claudetofocus:// protocol handler (windowless).
' Extracts the target hwnd from the URI and runs focus.ps1 hidden, so clicking
' a toast button never flashes a console window.
' focus.ps1 path is derived from this script's own location (portable).
On Error Resume Next

Dim uri, re, matches, hwnd, focusScript, shell, fso
uri = ""
If WScript.Arguments.Count > 0 Then uri = CStr(WScript.Arguments(0))

Set re = New RegExp
re.Pattern = "hwnd=(\d+)"
Set matches = re.Execute(uri)
If matches.Count > 0 Then
    hwnd = matches(0).SubMatches(0)
    Set fso = CreateObject("Scripting.FileSystemObject")
    focusScript = fso.GetParentFolderName(WScript.ScriptFullName) & "\focus.ps1"
    Set shell = CreateObject("WScript.Shell")
    shell.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & focusScript & """ """ & hwnd & """", 0, False
End If
