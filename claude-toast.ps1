<#
.SYNOPSIS
    Claude Code hook：任务完成时在右下角弹 Windows 原生 toast，点击「回到终端」按钮回到对应终端。
.DESCRIPTION
    由 ~/.claude/settings.json 的 Stop hook 调用（Claude 每次回应结束触发）。
    终端处于前台时不弹，避免打扰。
    内容动态：项目名（cwd）+ Claude 最后一条回复（last_assistant_message）；
    拿不到回复时退化为当前任务标题（控制台标题）。
    精确找到承载本会话的终端窗口：hook 进程自带隐藏控制台 → 先 FreeConsole，
    再向上逐个祖先 AttachConsole，首个成功者即本会话 shell，其控制台窗口的 owner
    就是承载本会话的 Windows Terminal 真实窗口（多窗口单进程下也精确）。
    toast 用 BurntToast 显示（手写 WinRT XML 在本机渲染为空，故弃用），
    「回到终端」按钮用协议激活 → claudetofocus:// 协议 → focus.ps1 聚焦该窗口。
    -Force：测试用，无视前台判断直接弹。
    每次触发写入 %TEMP%\claude-toast-actions.log 便于排查。
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$logFile = "$env:TEMP\claude-toast-actions.log"

# 读 hook 输入：stdin 是 UTF-8 字节，用字节流读取避免控制台编码破坏中文
$projectName = ''
$lastMsg = ''
try {
    $inStream = [Console]::OpenStandardInput()
    $ms = New-Object System.IO.MemoryStream
    $inStream.CopyTo($ms)
    $inStream.Dispose()
    $stdin = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    if ($stdin) {
        $h = $stdin | ConvertFrom-Json
        if ($h.cwd) { $projectName = Split-Path -Leaf $h.cwd }
        if ($h.'last_assistant_message') { $lastMsg = [string]$h.'last_assistant_message' }
    }
} catch { }

# 清洗标题：去加载动画字符、压缩空白、截断
function Clean-TaskTitle {
    param([string]$Raw)
    if (-not $Raw) { return '' }
    $t = $Raw -replace '^[^A-Za-z0-9一-鿿]+', ''
    $t = $t -replace '\s+', ' '
    $t = $t.Trim()
    if ($t.Length -gt 60) { $t = $t.Substring(0, 60) + '…' }
    return $t
}

# 清洗回复正文：去 markdown 符号、压成单行、截断
function Clean-Message {
    param([string]$Raw)
    if (-not $Raw) { return '' }
    $t = $Raw -replace '`{1,3}', ''
    $t = $t -replace '\*\*|__', ''
    $t = $t -replace '^#{1,6}\s*', ''
    $t = $t -replace '\s+', ' '
    $t = $t.Trim()
    if ($t.Length -gt 80) { $t = $t.Substring(0, 80) + '…' }
    return $t
}

# 找到承载本会话的终端窗口 + 读当前任务标题（控制台标题）
function Get-TerminalInfo {
    Add-Type -Namespace CliToast -Name Win32 -MemberDefinition @'
        [DllImport("kernel32.dll")] public static extern bool AttachConsole(int dwProcessId);
        [DllImport("kernel32.dll")] public static extern bool FreeConsole();
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern bool GetConsoleTitle(System.Text.StringBuilder text, int size);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, int uCmd);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
'@ -ErrorAction SilentlyContinue

    # 本进程可能自带隐藏控制台（Claude Code 用 CREATE_NO_WINDOW 派生 hook），
    # 有控制台时 AttachConsole 必然失败 → 先释放
    [CliToast.Win32]::FreeConsole()

    # 释放后若仍有控制台（继承自 Claude 会话）→ 控制台窗口的 owner 即目标窗口
    $cw = [CliToast.Win32]::GetConsoleWindow()
    if ($cw -ne [IntPtr]::Zero) {
        $sb = New-Object System.Text.StringBuilder 1024
        $title = ''
        if ([CliToast.Win32]::GetConsoleTitle($sb, 1024)) { $title = $sb.ToString() }
        $owner = [CliToast.Win32]::GetWindow($cw, 4)
        $target = $cw
        if ($owner -ne [IntPtr]::Zero) { $target = $owner }
        return @{ Hwnd = $target; Title = $title; Case = 'A' }
    }

    # 无控制台 → 向上逐个祖先 AttachConsole，首个成功者即本会话 shell
    $anc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    for ($i = 1; $i -lt 8 -and $anc; $i++) {
        $anc = Get-CimInstance Win32_Process -Filter "ProcessId=$($anc.ParentProcessId)" -ErrorAction SilentlyContinue
        if (-not $anc) { break }
        if ([CliToast.Win32]::AttachConsole([int]$anc.ProcessId)) {
            try {
                $cw = [CliToast.Win32]::GetConsoleWindow()
                if ($cw -ne [IntPtr]::Zero) {
                    $sb = New-Object System.Text.StringBuilder 1024
                    $title = ''
                    if ([CliToast.Win32]::GetConsoleTitle($sb, 1024)) { $title = $sb.ToString() }
                    $owner = [CliToast.Win32]::GetWindow($cw, 4)
                    if ($owner -ne [IntPtr]::Zero) { return @{ Hwnd = $owner; Title = $title; Case = 'B' } }
                    return @{ Hwnd = $cw; Title = $title; Case = 'B' }
                }
            } finally {
                [CliToast.Win32]::FreeConsole()
            }
        }
    }
    return $null
}

# 弹 toast：BurntToast 显示 + 「回到终端」按钮走协议激活聚焦窗口
function Show-ClaudeToast {
    param([string]$Title, [string]$Body, [string]$TargetHwnd)

    Import-Module BurntToast -ErrorAction Stop

    # toast 本体 + 「回到终端」按钮都走 claudetofocus:// 协议激活，点任何一处都回终端
    $uri = "claudetofocus://focus?hwnd=$TargetHwnd"
    $text1 = New-BTText -Text $Title
    $text2 = New-BTText -Text $Body

    # 应用 logo：用同目录的 claude-logo.png（Claude Code 图标）
    $bindingArgs = @{ Children = @($text1, $text2) }
    $logo = Join-Path $PSScriptRoot 'claude-logo.png'
    if (Test-Path $logo) {
        $bindingArgs['AppLogoOverride'] = New-BTImage -Source $logo -AppLogoOverride -Crop Circle
    }
    $binding = New-BTBinding @bindingArgs
    $visual = New-BTVisual -BindingGeneric $binding
    $btn = New-BTButton -Content '回到终端' -ActivationType Protocol -Arguments $uri
    $action = New-BTAction -Buttons $btn
    $content = New-BTContent -Visual $visual -Actions $action -ActivationType Protocol -Launch $uri -Duration Long
    Submit-BTNotification -Content $content -UniqueIdentifier 'claude-toast' | Out-Null
}

try {
    $info = Get-TerminalInfo
    if (-not $info -or $info.Hwnd -eq [IntPtr]::Zero) {
        "$(Get-Date -Format o) NO_TERMINAL" | Out-File -Append $logFile
        exit 0
    }

    # 终端在前台 → 不弹
    $fg = [CliToast.Win32]::GetForegroundWindow()
    if (-not $Force -and $fg -eq $info.Hwnd) {
        "$(Get-Date -Format o) FOCUSED case=$($info.Case) target=$($info.Hwnd)" | Out-File -Append $logFile
        exit 0
    }

    # 内容优先级：Claude 最后回复 > 任务标题 > 项目名 > 兜底
    $msg = Clean-Message -Raw $lastMsg
    $taskTitle = Clean-TaskTitle -Raw $info.Title
    if ($msg) {
        $body = if ($projectName) { "$projectName · $msg" } else { $msg }
    } elseif ($taskTitle) {
        $body = if ($projectName) { "$projectName · $taskTitle" } else { $taskTitle }
    } elseif ($projectName) {
        $body = "$projectName · 任务完成"
    } else {
        $body = '任务完成'
    }

    Show-ClaudeToast -Title 'Claude Code' -Body $body -TargetHwnd $info.Hwnd
    "$(Get-Date -Format o) FIRED case=$($info.Case) target=$($info.Hwnd) project=[$projectName] body=[$body]" | Out-File -Append $logFile
} catch {
    "$(Get-Date -Format o) ERROR: $_" | Out-File -Append $logFile
    # 静默失败，不影响 Claude Code 主流程；设 CLAUDE_TOAST_DEBUG=1 时暴露错误便于排查
    if ($env:CLAUDE_TOAST_DEBUG) { Write-Error $_ }
}
exit 0
