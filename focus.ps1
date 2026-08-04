<#
.SYNOPSIS
    claudetofocus:// 协议处理：把对应终端窗口拉回前台（保持其最大/还原状态）。
.DESCRIPTION
    由 focus.vbs 以隐藏方式调用，参数为目标窗口句柄（十进制 hwnd）。
    窗口最小化时才还原；最大化窗口不缩小，仅拉到前台。
    用 AttachThreadInput 绕过 Windows 前台锁，确保 SetForegroundWindow 生效。
    调试日志写入 %TEMP%\claude-toast-focus.log。
#>
param([string]$TargetHwnd)

$ErrorActionPreference = 'Stop'
$log = "$env:TEMP\claude-toast-focus.log"

$hwndNum = 0
if (-not [long]::TryParse($TargetHwnd, [ref]$hwndNum)) { exit 0 }
$hwnd = [IntPtr]$hwndNum
if ($hwnd -eq [IntPtr]::Zero) { exit 0 }

try {
    Add-Type -Namespace CliToast -Name Focus -MemberDefinition @'
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@ -ErrorAction SilentlyContinue

    $fgBefore = [CliToast.Focus]::GetForegroundWindow()
    "$(Get-Date -Format o) hwnd=$TargetHwnd fgBefore=$fgBefore" | Out-File -Append $log

    if ([CliToast.Focus]::IsIconic($hwnd)) {
        [CliToast.Focus]::ShowWindow($hwnd, 9) | Out-Null   # SW_RESTORE：仅最小化才还原
    }

    # AttachThreadInput：将当前线程挂到前台线程的输入队列，绕过前台锁
    $curThread = [CliToast.Focus]::GetCurrentThreadId()
    [uint32]$fgThread = 0
    [CliToast.Focus]::GetWindowThreadProcessId($fgBefore, [ref]$fgThread) | Out-Null
    if ($fgThread -ne 0) { [CliToast.Focus]::AttachThreadInput($curThread, $fgThread, $true) | Out-Null }

    $ok1 = [CliToast.Focus]::SetForegroundWindow($hwnd)
    $ok2 = [CliToast.Focus]::BringWindowToTop($hwnd)
    if ($fgThread -ne 0) { [CliToast.Focus]::AttachThreadInput($curThread, $fgThread, $false) | Out-Null }

    Start-Sleep -Milliseconds 300
    $fgAfter = [CliToast.Focus]::GetForegroundWindow()
    "  SetFG=$ok1 BringTop=$ok2 fgAfter=$fgAfter (目标=$TargetHwnd)" | Out-File -Append $log
} catch {
    "  ERROR: $_" | Out-File -Append $log
}
exit 0
