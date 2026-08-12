<#
.SYNOPSIS
    Claude Code hook：任务完成时在右下角弹 Windows 原生 toast，点击「回到终端」按钮回到对应终端。
.DESCRIPTION
    由 ~/.claude/settings.json 的 hook 调用：Stop（每次回应结束）与 Notification（Claude 要你做选择）。
    Notification 的 idle_prompt（闲置提醒）与 Stop 重复，只记日志不弹。
    终端处于前台时不弹，避免打扰；Warp 下再比对窗口标题，只有你正看着本会话那个标签页才静默。
    内容动态：项目名（cwd）+ Claude 最后一条回复（last_assistant_message）；
    拿不到回复时退化为当前任务标题（控制台标题）。
    回终端分两条路线：
      · Warp：用 Warp 注入的 WARP_FOCUS_URL（warp://session/<uuid>）直接激活，精确到标签页。
      · 其它终端（Windows Terminal 等）：hook 进程自带隐藏控制台 → 先 FreeConsole，
        再向上逐个祖先 AttachConsole，首个成功者即本会话 shell，其控制台窗口的 owner
        就是承载本会话的终端真实窗口（多窗口单进程下也精确）。
    toast 用 BurntToast 显示（手写 WinRT XML 在本机渲染为空，故弃用），
    「回到终端」按钮用协议激活跳转到上述 URI。
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
$hookEvent = ''
$transcriptPath = ''
try {
    $inStream = [Console]::OpenStandardInput()
    $ms = New-Object System.IO.MemoryStream
    $inStream.CopyTo($ms)
    $inStream.Dispose()
    $stdin = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    if ($stdin) {
        $h = $stdin | ConvertFrom-Json
        if ($h.cwd) { $projectName = Split-Path -Leaf $h.cwd }
        if ($h.'hook_event_name') { $hookEvent = [string]$h.'hook_event_name' }
        if ($h.'last_assistant_message') { $lastMsg = [string]$h.'last_assistant_message' }
        if ($h.'transcript_path') { $transcriptPath = [string]$h.'transcript_path' }
        # Notification 的正文永远是「Claude needs your permission」这一句死文案，
        # 不含工具名，光看通知无法判断该不该批 → 待批工具从 transcript 里补。
        if ($h.message) { $lastMsg = [string]$h.message }
    }
} catch { }

# 标题归一化：去开头的加载动画字符、压缩空白
function Get-TitleKey {
    param([string]$Raw)
    if (-not $Raw) { return '' }
    $t = $Raw -replace '^[^A-Za-z0-9一-鿿]+', ''
    $t = $t -replace '\s+', ' '
    return $t.Trim()
}

# 两个标题是否指向同一个会话：动画字符逐秒变化故先归一化，任一侧被截断也算命中
function Test-SameTitle {
    param([string]$A, [string]$B)
    $ka = Get-TitleKey -Raw $A
    $kb = Get-TitleKey -Raw $B
    if (-not $ka -or -not $kb) { return $false }
    return ($ka.StartsWith($kb) -or $kb.StartsWith($ka))
}

# 清洗标题：归一化后截断
function Clean-TaskTitle {
    param([string]$Raw)
    $t = Get-TitleKey -Raw $Raw
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

# 从 transcript 里取出正在等你批准的那个工具调用。
# Notification 的 message 恒为「Claude needs your permission」，不带工具名；
# transcript 的最后一个 tool_use 若还没有对应的 tool_result，就是卡在权限确认上的那个。
function Get-PendingTool {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }

    # transcript 可达数 MB，只读尾部若干行
    $tail = Get-Content $Path -Tail 250 -ErrorAction SilentlyContinue
    if (-not $tail) { return $null }

    $lastUse = $null
    $resultIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($line in $tail) {
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (-not $o.message.content) { continue }
        foreach ($c in $o.message.content) {
            if ($c.type -eq 'tool_use')    { $lastUse = $c }
            elseif ($c.type -eq 'tool_result' -and $c.tool_use_id) { [void]$resultIds.Add([string]$c.tool_use_id) }
        }
    }
    if (-not $lastUse) { return $null }
    # 已经有结果 = 早就执行完了，不是本次要批的
    if ($lastUse.id -and $resultIds.Contains([string]$lastUse.id)) { return $null }

    $name = [string]$lastUse.name
    $in = $lastUse.input
    $detail = ''
    switch -Regex ($name) {
        '^(Bash|PowerShell)$' {
            # description 是给人看的一句话摘要，比原始命令好读；没有再退回命令首行
            if ($in.description) { $detail = [string]$in.description }
            elseif ($in.command) { $detail = ([string]$in.command -split "`n")[0] }
        }
        '^(Edit|Write|Read|NotebookEdit)$' {
            if ($in.file_path) { $detail = Split-Path -Leaf ([string]$in.file_path) }
        }
        '^(Glob|Grep)$'  { if ($in.pattern) { $detail = [string]$in.pattern } }
        '^WebFetch$'     { if ($in.url)     { $detail = [string]$in.url } }
        '^(Task|Agent)$' { if ($in.description) { $detail = [string]$in.description } }
        default {
            if ($in.description) { $detail = [string]$in.description }
            elseif ($in.command) { $detail = ([string]$in.command -split "`n")[0] }
        }
    }
    return @{ Name = $name; Detail = $detail }
}

# Win32 声明：寻窗与前台判断共用
function Initialize-Win32 {
    Add-Type -Namespace CliToast -Name Win32 -MemberDefinition @'
        [DllImport("kernel32.dll")] public static extern bool AttachConsole(int dwProcessId);
        [DllImport("kernel32.dll")] public static extern bool FreeConsole();
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern bool GetConsoleTitle(System.Text.StringBuilder text, int size);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, int uCmd);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int procId);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int size);
'@ -ErrorAction SilentlyContinue
}

# 前台窗口的进程名与标题（Warp 路线下用它判断是否该静默）
function Get-ForegroundWindowInfo {
    Initialize-Win32
    $result = @{ Process = ''; Title = '' }
    $fg = [CliToast.Win32]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero) { return $result }
    $procId = 0
    [CliToast.Win32]::GetWindowThreadProcessId($fg, [ref]$procId) | Out-Null
    if ($procId -ne 0) {
        try { $result.Process = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { }
    }
    $sb = New-Object System.Text.StringBuilder 1024
    [CliToast.Win32]::GetWindowText($fg, $sb, 1024) | Out-Null
    $result.Title = $sb.ToString()
    return $result
}

# 找到承载本会话的终端窗口 + 读当前任务标题（控制台标题）
function Get-TerminalInfo {
    Initialize-Win32

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

# 弹 toast：BurntToast 显示 + 「回到终端」按钮走协议激活回到终端
function Show-ClaudeToast {
    param([string]$Title, [string]$Body, [string]$LaunchUri)

    Import-Module BurntToast -ErrorAction Stop

    # toast 本体 + 「回到终端」按钮都走同一个协议 URI，点任何一处都回终端
    $uri = $LaunchUri
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
    # Notification 的 idle_prompt（「Claude is waiting for your input」，闲置约 60 秒触发）
    # 与本次回应结束时的 Stop 通知内容重复，只记日志不弹；permission_prompt 照弹。
    if ($hookEvent -eq 'Notification' -and $lastMsg -match 'waiting for your input') {
        "$(Get-Date -Format o) SKIP_IDLE" | Out-File -Append $logFile
        exit 0
    }

    # Warp 走自己的会话 URL：Warp 的伪控制台窗口没有 owner，hwnd 路线只能拿到一个不可见窗口，
    # SetForegroundWindow 会「成功」但界面不动。WARP_FOCUS_URL 由 Warp shell 注入并被 hook 继承。
    $warpUri = $env:WARP_FOCUS_URL

    if ($warpUri) {
        # Warp 窗口标题实时跟随当前标签页，与本会话控制台标题一致即说明你正看着这个标签页 → 不弹。
        # （warp.sqlite 的 active_tab_index 只在特定时刻落盘，切标签页不写，不能用）
        # 拿不到本会话标题时按「不在当前标签页」处理：宁可多弹一次，也不吞掉通知。
        $term = Get-TerminalInfo
        $sessionTitle = if ($term) { $term.Title } else { '' }
        $fgWindow = Get-ForegroundWindowInfo
        if (-not $Force -and $fgWindow.Process -eq 'warp' -and (Test-SameTitle $fgWindow.Title $sessionTitle)) {
            "$(Get-Date -Format o) FOCUSED event=$hookEvent route=warp title=[$sessionTitle]" | Out-File -Append $logFile
            exit 0
        }
        $launchUri = $warpUri
        $taskTitle = Clean-TaskTitle -Raw $sessionTitle
        $route = 'warp'
    } else {
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
        $launchUri = "claudetofocus://focus?hwnd=$($info.Hwnd)"
        $taskTitle = Clean-TaskTitle -Raw $info.Title
        $route = "hwnd case=$($info.Case) target=$($info.Hwnd)"
    }

    # 权限请求：把死文案换成「需要授权：<工具> — <做什么>」，通知里就能判断该不该批
    $msg = ''
    if ($hookEvent -eq 'Notification' -and $lastMsg -match 'permission') {
        $pending = Get-PendingTool -Path $transcriptPath
        if ($pending) {
            $msg = if ($pending.Detail) { "需要授权：$($pending.Name) — $($pending.Detail)" }
                   else                 { "需要授权：$($pending.Name)" }
            $msg = Clean-Message -Raw $msg
        }
    }

    # 内容优先级：待批工具 > Claude 最后回复 > 任务标题 > 项目名 > 兜底
    if (-not $msg) { $msg = Clean-Message -Raw $lastMsg }
    if ($msg) {
        $body = if ($projectName) { "$projectName · $msg" } else { $msg }
    } elseif ($taskTitle) {
        $body = if ($projectName) { "$projectName · $taskTitle" } else { $taskTitle }
    } elseif ($projectName) {
        $body = "$projectName · 任务完成"
    } else {
        $body = '任务完成'
    }

    Show-ClaudeToast -Title 'Claude Code' -Body $body -LaunchUri $launchUri
    "$(Get-Date -Format o) FIRED event=$hookEvent route=$route project=[$projectName] body=[$body]" | Out-File -Append $logFile
} catch {
    "$(Get-Date -Format o) ERROR: $_" | Out-File -Append $logFile
    # 静默失败，不影响 Claude Code 主流程；设 CLAUDE_TOAST_DEBUG=1 时暴露错误便于排查
    if ($env:CLAUDE_TOAST_DEBUG) { Write-Error $_ }
}
exit 0
