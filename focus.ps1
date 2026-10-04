<#
.SYNOPSIS
    claudetofocus:// 协议处理：把对应终端窗口拉回前台（保持其最大/还原状态）。
.DESCRIPTION
    由 focus.vbs 以隐藏方式调用，参数为目标窗口句柄（十进制 hwnd）；
    Pebrel 下改传 -PebrelPane（窗格 id）与 -PebrelPid（Pebrel 主进程 pid）。
    窗口最小化时才还原；最大化窗口不缩小，仅拉到前台。
    用 AttachThreadInput 绕过 Windows 前台锁，确保 SetForegroundWindow 生效。
    调试日志写入 %TEMP%\claude-toast-focus.log。
#>
param([string]$TargetHwnd, [string]$PebrelPane, [string]$PebrelPid)

$ErrorActionPreference = 'Stop'
$log = "$env:TEMP\claude-toast-focus.log"

# Pebrel：先让它自己切到该窗格所在的标签页并聚焦窗格，再走下面的通用逻辑把主窗口拉到前台
# （协议激活来的进程没有前台权，Pebrel 自己 activate 窗口不一定成功）。
if ($PebrelPane) {
    try {
        $proc = $null
        if ($PebrelPid) { $proc = Get-Process -Id $PebrelPid -ErrorAction SilentlyContinue }
        if (-not $proc) {
            $proc = Get-Process pebrel -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
        }
        # Pebrel 主程序与 CLI 是同一个 pebrel.exe；协议激活的进程没有 PEBREL_* 环境变量，CLI 会自己找到 Runtime
        $cli = if ($proc -and $proc.Path) { $proc.Path } else { (Get-Command pebrel -ErrorAction SilentlyContinue).Source }
        if ($cli) {
            $r = (& $cli ctl focus --pane $PebrelPane --timeout-ms 5000 2>&1 | Out-String).Trim()
            # 成功时回包带整份快照，只记 ok；失败才记原文
            if ($r -match '"ok"\s*:\s*true') { $r = 'ok' } elseif ($r.Length -gt 300) { $r = $r.Substring(0, 300) + '…' }
            "$(Get-Date -Format o) pebrel pane=$PebrelPane focus=$r" | Out-File -Append $log
        }
        if ($proc) { $proc.Refresh(); $TargetHwnd = [string]$proc.MainWindowHandle }
    } catch {
        "$(Get-Date -Format o) pebrel pane=$PebrelPane ERROR: $_" | Out-File -Append $log
    }
}

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
