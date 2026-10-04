' claudetofocus:// protocol handler (windowless).
' Extracts the target from the URI and runs focus.ps1 hidden, so clicking
' a toast button never flashes a console window.
'   claudetofocus://focus?hwnd=<hwnd>                         -> focus.ps1 <hwnd>
'   claudetofocus://focus?pebrel_pane=<id>&pebrel_pid=<pid>  -> focus.ps1 -PebrelPane <id> -PebrelPid <pid>
' focus.ps1 path is derived from this script's own location (portable).
On Error Resume Next

Dim uri, re, matches, args, focusScript, shell, fso
uri = ""
If WScript.Arguments.Count > 0 Then uri = CStr(WScript.Arguments(0))

args = ""
Set re = New RegExp
re.Pattern = "pebrel_pane=(\d+)"
Set matches = re.Execute(uri)
If matches.Count > 0 Then
    args = "-PebrelPane " & matches(0).SubMatches(0)
    re.Pattern = "pebrel_pid=(\d+)"
    Set matches = re.Execute(uri)
    If matches.Count > 0 Then args = args & " -PebrelPid " & matches(0).SubMatches(0)
Else
    re.Pattern = "hwnd=(\d+)"
    Set matches = re.Execute(uri)
    If matches.Count > 0 Then args = """" & matches(0).SubMatches(0) & """"
End If

If args <> "" Then
    Set fso = CreateObject("Scripting.FileSystemObject")
    focusScript = fso.GetParentFolderName(WScript.ScriptFullName) & "\focus.ps1"
    Set shell = CreateObject("WScript.Shell")
    shell.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & focusScript & """ " & args, 0, False
End If
