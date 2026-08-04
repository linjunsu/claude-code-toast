# claude-code-toast

> Claude Code 任务完成右下角弹窗 + 一键回到对应终端（Windows 11 原生 toast）

Claude Code 每次回应结束，如果你的终端不在前台，右下角会弹出 Windows 原生通知：

- **标题**：Claude Code
- **正文**：`<项目名> · <Claude 最后一条回复摘要>`（动态，不写死）
- **按钮**：「回到终端」——点击精确切回承载该会话的终端窗口（多窗口多会话不混淆）

行为复刻 GitHub Codex：**窗口不在这页才弹**；终端在前台时不打扰。

---

## ✨ AI 一句话自动配置

把下面这句话发给你的 AI（Claude Code / 其它能在本机跑命令的编程 AI），它会自动完成全部配置：

> 请读取本仓库 README.md 并按「手动安装」章节自动完成 claude-code-toast 配置：运行 setup.ps1 注册 claudetofocus:// 协议并安装 BurntToast，再把 claude-toast.ps1 的绝对路径以 hooks.Stop 形式合并进 ~/.claude/settings.json，配置完成后告诉我。

---

## 手动安装

1. 把本仓库放到任意目录（例如 `C:\ljs\claude-code-toast`）。
2. 打开 PowerShell 运行：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
   ```
   脚本会：注册 `claudetofocus://` 协议、安装 BurntToast（含 Windows PowerShell 5.1 副本）、输出 settings.json 配置片段。
3. 把输出片段合并进 `~/.claude/settings.json`（顶层加 `hooks`；已有 `hooks` 就合并 `Stop` 键，路径换成实际的）：
   ```json
   "hooks": {
     "Stop": [
       {
         "hooks": [
           {
             "type": "command",
             "command": "powershell",
             "args": [
               "-NoProfile",
               "-ExecutionPolicy",
               "Bypass",
               "-File",
               "C:\\ljs\\claude-code-toast\\claude-toast.ps1"
             ],
             "timeout": 15
           }
         ]
       }
     ]
   }
   ```
4. 重启 Claude Code（或开一次 `/hooks` 重载配置）。

**依赖**：Windows 11、Windows Terminal、PowerShell 5.1+、Claude Code。

---

## 行为

- **触发**：`Stop` hook（Claude 每次回应结束）
- **内容优先级**：Claude 最后回复摘要 > 当前任务标题（控制台标题）> 项目名 > 兜底文案
- **前台判断**：终端窗口在前台时不弹
- **精确寻窗**：`FreeConsole` + 逐祖先 `AttachConsole` → 控制台窗口的 owner = 承载该会话的 Windows Terminal 窗口（多窗口单进程也精确）
- **点击聚焦**：toast「回到终端」按钮走 `claudetofocus://` 协议 → `focus.ps1` 用 `AttachThreadInput` 绕过 Windows 前台锁

---

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```
再手动：删掉 `~/.claude/settings.json` 的 `hooks.Stop`、删除本目录。

---

## 常见问题 / 已知坑

- **toast 内容为空 / 只显示「新通知」**：本机实测手写 WinRT toast XML（`LoadXml` + `encoding` 声明）会渲染成空横幅，必须用 BurntToast 模块。
- **hook 找不到终端窗口**：Claude Code 在 Windows 上以隐藏控制台（`CREATE_NO_WINDOW`）派生 hook，`GetConsoleWindow()=0` 且 `AttachConsole` 直接失败；需先 `FreeConsole()` 再逐祖先 `AttachConsole`。
- **点了按钮终端不回来**：从 toast 协议激活启动的进程没有「前台权」，`SetForegroundWindow` 会静默失败；用 `AttachThreadInput` 绕过。
- **没弹窗排查**：看 `%TEMP%\claude-toast-actions.log`（记录 `NO_TERMINAL` / `FOCUSED` / `FIRED` / `ERROR`）。

---

## License

MIT
