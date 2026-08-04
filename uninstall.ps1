<#
.SYNOPSIS
    claude-code-toast 卸载：删除 claudetofocus:// 协议注册。
.DESCRIPTION
    运行后还需手动：从 ~/.claude/settings.json 删除 Stop hook、删除本目录。
#>
$ErrorActionPreference = 'Stop'
$key = 'HKCU:\Software\Classes\claudetofocus'
if (Test-Path $key) {
    Remove-Item $key -Recurse -Force
    Write-Host "已删除 claudetofocus:// 协议注册"
} else {
    Write-Host "协议注册不存在，跳过"
}
Write-Host ""
Write-Host "还需手动："
Write-Host "  1. 从 ~/.claude/settings.json 删除 hooks.Stop"
Write-Host "  2. 删除本仓库目录"
