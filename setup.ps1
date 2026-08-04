<#
.SYNOPSIS
    claude-code-toast 一键安装：注册 claudetofocus:// 协议 + 安装 BurntToast + 输出 settings.json 配置。
.DESCRIPTION
    支持选择用哪个 PowerShell 跑 hook：
      -PowerShell 7 ：hook 命令用 pwsh，BurntToast 装到 PowerShell 7（原生，无需额外复制）。
      -PowerShell 5（默认）：hook 命令用 powershell（Windows PowerShell 5.1，系统自带），
                          BurntToast 若 PS5.1 看不到会自动复制一份给它。
    把本仓库放到任意目录后运行本脚本即可完成大半配置；
    最后一步把 Stop hook 加进 ~/.claude/settings.json（见 README「AI 一键配置」或本脚本末尾输出）。
#>
[CmdletBinding()]
param(
    [ValidateSet('5', '7')]
    [string]$PowerShell = '5'
)

$ErrorActionPreference = 'Stop'
$usePwsh = ($PowerShell -eq '7')
$hookCommand = 'powershell'
if ($usePwsh) { $hookCommand = 'pwsh' }

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs = Join-Path $dir 'focus.vbs'
$toast = Join-Path $dir 'claude-toast.ps1'
if (-not (Test-Path $vbs)) { throw "找不到 focus.vbs: $vbs" }
if (-not (Test-Path $toast)) { throw "找不到 claude-toast.ps1: $toast" }

Write-Host "=== [1/3] 注册 claudetofocus:// 协议 ==="
$wscript = "$env:WINDIR\System32\wscript.exe"
$handler = "`"$wscript`" `"$vbs`" `"%1`""
$schemeKey = 'HKCU:\Software\Classes\claudetofocus'
New-Item -Path $schemeKey -Force | Out-Null
Set-ItemProperty -Path $schemeKey -Name '(Default)' -Value 'URL: claudetofocus Protocol'
Set-ItemProperty -Path $schemeKey -Name 'URL Protocol' -Value ''
New-Item -Path "$schemeKey\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$schemeKey\shell\open\command" -Name '(Default)' -Value $handler
Write-Host "已注册: $handler"

Write-Host "=== [2/3] 安装 BurntToast ==="
if (-not (Get-Module -ListAvailable BurntToast)) {
    Write-Host "安装 BurntToast（当前 PowerShell）..."
    Install-Module BurntToast -Scope CurrentUser -Force -ErrorAction Continue
}
if (-not $usePwsh) {
    # Windows PowerShell 5.1 看不到 pwsh 装的模块 → 复制一份
    $ps51 = powershell -NoProfile -Command "if (Get-Module -ListAvailable BurntToast) { 'yes' }"
    if ($ps51 -ne 'yes') {
        $bt = Get-Module -ListAvailable BurntToast | Select-Object -First 1
        if ($bt) {
            $src = Split-Path $bt.ModuleBase
            $dest = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules"
            New-Item -ItemType Directory -Force $dest | Out-Null
            Copy-Item -Recurse -Force $src "$dest\BurntToast"
            Write-Host "已为 Windows PowerShell 5.1 复制 BurntToast"
        }
    }
}
Write-Host "BurntToast 就绪（hook 将使用: $hookCommand）"

Write-Host "=== [3/3] 配置 ~/.claude/settings.json ==="
Write-Host "在 settings.json 顶层加以下内容（已有 hooks 就合并 Stop 键，路径改为上面的绝对路径）："
Write-Host ""
Write-Host '  "hooks": {'
Write-Host '    "Stop": ['
Write-Host '      {'
Write-Host '        "hooks": ['
Write-Host '          {'
Write-Host '            "type": "command",'
Write-Host "            `"command`": `"$hookCommand`","
Write-Host "            `"args`": [`"-NoProfile`", `"-ExecutionPolicy`", `"Bypass`", `"-File`", `"$toast`"],"
Write-Host '            "timeout": 15'
Write-Host '          }'
Write-Host '        ]'
Write-Host '      }'
Write-Host '    ]'
Write-Host '  }'
Write-Host ""
Write-Host "完成后重启 Claude Code（或开一次 /hooks 重载）。也可直接把本仓库 README 顶部的「AI 一句话」发给 AI 让它代劳。"
