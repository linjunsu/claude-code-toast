# claude-code-toast

> Claude Code 任务完成右下角弹窗 + 一键回到对应终端（Windows 11 原生 toast）

Claude Code **每次回应结束**、以及**需要你做选择时**（批准命令、确认方案），如果你的终端不在前台，右下角会弹出 Windows 原生通知：

- **标题**：Claude Code
- **正文**：`<项目名> · <Claude 最后一条回复摘要>`；要你做选择时是 `<项目名> · 需要授权：<工具> — <做什么>`，例如 `workbench · 需要授权：PowerShell — 重启开发服务器`
- **按钮**：「回到终端」——点击精确切回承载该会话的终端窗口（多窗口多会话不混淆）；Warp 下还能切回该会话所在的标签页

行为复刻 GitHub Codex：**窗口不在这页才弹**；终端在前台时不打扰。

---

## ✨ AI 一句话自动配置

把下面这句话发给你的 AI（Claude Code / 其它能在本机跑命令的编程 AI），它会自动完成全部配置：

> 请先克隆 https://github.com/linjunsu/claude-code-toast 到全局目录 ~/.claude/claude-code-toast（Windows 路径为 C:\Users\<你的用户名>\.claude\claude-code-toast；务必放在全局目录下，不要克隆进当前项目目录），然后读取该仓库 README.md 并按「手动安装」章节自动完成 claude-code-toast 配置：运行 setup.ps1 注册 claudetofocus:// 协议并安装 BurntToast（hook 默认用 Windows PowerShell 5.1，可加 -PowerShell 7 改用 PowerShell 7），再把 claude-toast.ps1 的绝对路径同时以 hooks.Stop 和 hooks.Notification 两个键合并进 ~/.claude/settings.json，配置完成后告诉我。

---

## 手动安装

1. 把本仓库放到全局目录 `~/.claude` 下（例如 `C:\Users\<你的用户名>\.claude\claude-code-toast`）。
2. 打开 PowerShell 运行（可先看「选择 PowerShell 版本」决定要不要加 `-PowerShell 7`）：
   ```powershell
   # 默认用 Windows PowerShell 5.1 跑 hook
   powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
   # 或改用 PowerShell 7（更快、BurntToast 原生安装，无需复制模块）
   powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -PowerShell 7
   ```
   脚本会：注册 `claudetofocus://` 协议、安装 BurntToast、按所选版本输出 settings.json 配置片段。
3. 把输出片段合并进 `~/.claude/settings.json`（顶层加 `hooks`；已有 `hooks` 就合并 `Stop`、`Notification` 两个键，路径换成实际的）。`command` 用 `pwsh` 还是 `powershell` 要和上一步的选择一致：
   ```json
   "hooks": {
     "Stop": [
       {
         "hooks": [
           {
             "type": "command",
             "command": "pwsh",
             "args": [
               "-NoProfile",
               "-ExecutionPolicy",
               "Bypass",
               "-File",
               "C:\\Users\\<你的用户名>\\.claude\\claude-code-toast\\claude-toast.ps1"
             ],
             "timeout": 15
           }
         ]
       }
     ],
     "Notification": [
       {
         "hooks": [
           {
             "type": "command",
             "command": "pwsh",
             "args": [
               "-NoProfile",
               "-ExecutionPolicy",
               "Bypass",
               "-File",
               "C:\\Users\\<你的用户名>\\.claude\\claude-code-toast\\claude-toast.ps1"
             ],
             "timeout": 15
           }
         ]
       }
     ]
   }
   ```
   > 用 PowerShell 5.1 的话，把 `"command": "pwsh"` 改成 `"command": "powershell"`。
4. 重启 Claude Code（或开一次 `/hooks` 重载配置）。

**依赖**：Windows 11、Windows Terminal 或 Warp、PowerShell 5.1 或 7、Claude Code。

## 选择 PowerShell 版本（5 / 7）

| 选项 | hook 命令 | BurntToast | 说明 |
|---|---|---|---|
| `-PowerShell 5`（默认） | `powershell` | 装好后若 PS5.1 看不到会自动复制一份 | Windows 系统自带，任何机器都能跑 |
| `-PowerShell 7` | `pwsh` | 装到 PowerShell 7，原生可用 | 启动更快、默认 UTF-8，需已装 pwsh |

---

## 行为

- **触发**：`Stop`（每次回应结束）+ `Notification`（Claude 要你做选择，如批准命令）
- **内容优先级**：`Notification` 用待批工具（从 transcript 取）> 事件自带的 `message`；`Stop` 用 Claude 最后回复摘要 > 当前任务标题（控制台标题）> 项目名 > 兜底文案
- **权限通知为什么要读 transcript**：`Notification` 的 `message` 恒为 `Claude needs your permission` 这一句死文案，不含工具名，光看通知没法判断该不该批。改为顺着 hook 给的 `transcript_path` 取会话记录尾部，最后一个还没有对应 `tool_result` 的 `tool_use` 就是卡在权限确认上的那个；`Bash`/`PowerShell` 取它的 `description`（拿不到退回命令首行），`Edit`/`Write`/`Read` 取文件名，`Grep`/`Glob` 取搜索模式，`WebFetch` 取 URL
- **不重复打扰**：`Notification` 的 `idle_prompt`（闲置约 60 秒的「等你输入」提醒）与 `Stop` 那条内容重复，只记日志不弹
- **前台判断**：终端窗口在前台时不弹。Warp 下改为比对标题——Warp 窗口标题实时跟随当前标签页，与本会话控制台标题一致才静默，所以**别的标签页跑完照样弹**
- **回终端分两条路线**（按环境变量自动选，两边都不用配置）：
  - **Warp**：读 Warp 注入的 `WARP_FOCUS_URL`（`warp://session/<uuid>`），toast 直接用它做协议激活，由 Warp 自己切窗口 + 切标签页，不走寻窗和 `focus.ps1`
  - **Windows Terminal 等**：`FreeConsole` + 逐祖先 `AttachConsole` 精确寻窗（控制台窗口的 owner = 承载该会话的终端窗口，多窗口单进程也精确），toast 走 `claudetofocus://` 协议 → `focus.ps1` 用 `AttachThreadInput` 绕过 Windows 前台锁

---

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```
再手动：删掉 `~/.claude/settings.json` 的 `hooks.Stop` 和 `hooks.Notification`、删除本目录。

---

## 常见问题 / 已知坑

- **toast 内容为空 / 只显示「新通知」**：本机实测手写 WinRT toast XML（`LoadXml` + `encoding` 声明）会渲染成空横幅，必须用 BurntToast 模块。
- **hook 找不到终端窗口**：Claude Code 在 Windows 上以隐藏控制台（`CREATE_NO_WINDOW`）派生 hook，`GetConsoleWindow()=0` 且 `AttachConsole` 直接失败；需先 `FreeConsole()` 再逐祖先 `AttachConsole`。
- **点了按钮终端不回来**：从 toast 协议激活启动的进程没有「前台权」，`SetForegroundWindow` 会静默失败；用 `AttachThreadInput` 绕过。
- **Warp 下点了没反应**：Warp 的 `PseudoConsoleWindow` 不挂 owner（Windows Terminal 会挂），寻窗只能拿到那个不可见窗口，`SetForegroundWindow` 返回 True 但界面不动。所以 Warp 走 `WARP_FOCUS_URL` 而不是 hwnd。
- **Warp 下怎么判断「你在看哪个标签页」**：`warp.sqlite` 里的 `windows.active_tab_index` 切标签页时**不落盘**（实测切换一分钟内数据库零写入），不可用；可用的是 Warp 窗口标题，它实时跟随当前标签页。局限：两个标签页的会话标题恰好相同时会误判为同一个而静默。
- **不要同时装 Warp 官方的 [claude-code-warp](https://github.com/warpdotdev/claude-code-warp) 插件**，那套走 OSC 777 让 Warp 自己弹通知，和本项目重复，会收到两条。
- **没弹窗排查**：看 `%TEMP%\claude-toast-actions.log`（记录 `NO_TERMINAL` / `FOCUSED` / `FIRED` / `ERROR`，`route=warp` / `route=hwnd` 标明走的哪条路线）。

---

## License

MIT
