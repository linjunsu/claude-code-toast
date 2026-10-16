' claudetofocus:// protocol handler (windowless).
' Extracts the target from the URI and runs focus.ps1 hidden, so clicking
' a toast button never flashes a console window.
'   claudetofocus://focus?hwnd=<hwnd>                         -> focus.ps1 <hwnd>
'   claudetofocus://focus?pebrel_pane=<id>&pebrel_pid=<pid>  -> pebrel.exe ctl focus --pane <id>, then
'                                                               focus.ps1 -PebrelPane <id> -PebrelRc <rc> -PebrelPid <pid>
' Pebrel fast path: pebrel.exe is called straight from here, skipping the ~0.5s PowerShell
' cold start, so the pane switch shows up first; focus.ps1 then only does the fallback
' window raise and logging.
' focus.ps1 path is derived from this script's own location (portable).
On Error Resume Next

Dim uri, re, matches, args, focusScript, shell, fso, pane, ppid, rc
uri = ""
If WScript.Arguments.Count > 0 Then uri = CStr(WScript.Arguments(0))

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

' pebrel.exe: default per-user install path first (instant), then the running process via WMI, then PATH.
Function PebrelExe(pid)
    Dim p, proc
    p = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\Pebrel\pebrel.exe")
    If fso.FileExists(p) Then
        PebrelExe = p
        Exit Function
    End If
    If pid <> "" Then
        Set proc = Nothing
        Set proc = GetObject("winmgmts:").Get("Win32_Process.Handle='" & pid & "'")
        If Not proc Is Nothing Then
            If Not IsNull(proc.ExecutablePath) Then
                PebrelExe = proc.ExecutablePath
                Exit Function
            End If
        End If
    End If
    PebrelExe = "pebrel"
End Function

args = ""
Set re = New RegExp
re.Pattern = "pebrel_pane=(\d+)"
Set matches = re.Execute(uri)
If matches.Count > 0 Then
    pane = matches(0).SubMatches(0)
    ppid = ""
    re.Pattern = "pebrel_pid=(\d+)"
    Set matches = re.Execute(uri)
    If matches.Count > 0 Then ppid = matches(0).SubMatches(0)
    rc = -1
    rc = shell.Run("""" & PebrelExe(ppid) & """ ctl focus --pane " & pane & " --timeout-ms 5000", 0, True)
    args = "-PebrelPane " & pane & " -PebrelRc " & rc
    If ppid <> "" Then args = args & " -PebrelPid " & ppid
Else
    re.Pattern = "hwnd=(\d+)"
    Set matches = re.Execute(uri)
    If matches.Count > 0 Then args = """" & matches(0).SubMatches(0) & """"
End If

If args <> "" Then
    focusScript = fso.GetParentFolderName(WScript.ScriptFullName) & "\focus.ps1"
    shell.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & focusScript & """ " & args, 0, False
End If
