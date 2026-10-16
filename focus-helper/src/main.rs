//! claudetofocus:// 协议处理程序（无窗口）。
//!
//! Pebrel 路线（`claudetofocus://focus?pebrel_pane=<id>&pebrel_pid=<pid>`）：
//! 直接连 Pebrel 的 Runtime API（`%APPDATA%\Pebrel\runtime.port` 里的本机 TCP 端口 + 口令，
//! 一行 JSON 一次请求）发 `window.focus`，不再经 wscript → pebrel.exe ctl 两次起进程。
//! 请求一发出（不等回包）就同时把 Pebrel 窗口拉到前台：点击带来的前台权在本进程手里，
//! Pebrel 自己激活常被前台锁拦下，等它回包再拉要多等约 100ms。回包后若仍不在前台再拉一次。
//! 窗格不存在时退一步只聚焦窗口；Runtime 连不上就整条交回 focus.vbs（老路线）。
//!
//! 其他 URI（hwnd=…）原样交给同目录的 focus.vbs。
//! 日志追加到 %TEMP%\claude-toast-focus.log（UTF-16LE，与 focus.ps1 一致）。
#![windows_subsystem = "windows"]

use std::io::{BufRead, BufReader, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::time::{Duration, Instant};

type Hwnd = isize;

#[link(name = "user32")]
extern "system" {
    fn GetForegroundWindow() -> Hwnd;
    fn SetForegroundWindow(hwnd: Hwnd) -> i32;
    fn BringWindowToTop(hwnd: Hwnd) -> i32;
    fn ShowWindow(hwnd: Hwnd, cmd: i32) -> i32;
    fn IsIconic(hwnd: Hwnd) -> i32;
    fn IsWindowVisible(hwnd: Hwnd) -> i32;
    fn GetWindow(hwnd: Hwnd, cmd: u32) -> Hwnd;
    fn GetWindowThreadProcessId(hwnd: Hwnd, pid: *mut u32) -> u32;
    fn AttachThreadInput(attach: u32, attach_to: u32, on: i32) -> i32;
    fn EnumWindows(cb: extern "system" fn(Hwnd, isize) -> i32, lparam: isize) -> i32;
}

#[link(name = "kernel32")]
extern "system" {
    fn GetCurrentThreadId() -> u32;
    fn GetLocalTime(st: *mut SystemTime);
}

#[repr(C)]
#[derive(Default)]
struct SystemTime {
    year: u16,
    month: u16,
    day_of_week: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    millis: u16,
}

const GW_OWNER: u32 = 4;
const SW_RESTORE: i32 = 9;

fn main() {
    let uri = std::env::args().nth(1).unwrap_or_default();
    if let Some(pane) = param(&uri, "pebrel_pane") {
        let t0 = Instant::now();
        let uri_pid: Option<u32> = param(&uri, "pebrel_pid").and_then(|p| p.parse().ok());
        // 请求写出去就拉窗口（uri 里的 pid 可能是旧 Pebrel 的，找不到窗口就算了，回包后再补）
        let mut early = String::from("-");
        let mut on_sent = || {
            if let Some(pid) = uri_pid {
                let sent = t0.elapsed().as_millis();
                let r = raise_process_window(pid);
                early = format!("{r}@{sent}-{}ms", t0.elapsed().as_millis());
            }
        };
        match pebrel_focus(&pane, &mut on_sent) {
            Ok((ok, pid)) => {
                let ctl_ms = t0.elapsed().as_millis();
                let fg = pid.or(uri_pid).map(raise_process_window).unwrap_or("no-pid");
                let focus = if ok { "ok" } else { "pane-missing,window-only" };
                log(&format!("helper pebrel pane={pane} focus={focus} ctl={ctl_ms}ms early={early} fg={fg}"));
                return;
            }
            Err(e) => log(&format!("helper pebrel pane={pane} ERROR: {e} -> focus.vbs")),
        }
    }
    run_vbs(&uri);
}

/// URI 里 `key=<数字>` 的值
fn param(uri: &str, key: &str) -> Option<String> {
    let pat = format!("{key}=");
    let start = uri.find(&pat)? + pat.len();
    let digits: String = uri[start..].chars().take_while(|c| c.is_ascii_digit()).collect();
    (!digits.is_empty()).then_some(digits)
}

/// 发 window.focus 到窗格；窗格不在了就只聚焦窗口。返回（窗格是否切成功，Pebrel pid）
fn pebrel_focus(pane: &str, on_sent: &mut dyn FnMut()) -> Result<(bool, Option<u32>), String> {
    let appdata = std::env::var("APPDATA").map_err(|_| "no APPDATA")?;
    let endpoint = std::fs::read_to_string(format!("{appdata}\\Pebrel\\runtime.port"))
        .map_err(|e| format!("runtime.port: {e}"))?;
    let mut parts = endpoint.split_whitespace();
    let port: u16 = parts.next().and_then(|p| p.parse().ok()).ok_or("bad port")?;
    let token = parts.next().ok_or("no token")?;

    let resp = request(port, token, &format!("{{\"pane_id\":{pane}}}"), on_sent)?;
    if is_ok(&resp) {
        return Ok((true, json_u32(&resp, "\"process_id\":")));
    }
    let resp = request(port, token, "{}", &mut || {})?;
    Ok((false, json_u32(&resp, "\"process_id\":")))
}

fn request(port: u16, token: &str, params: &str, on_sent: &mut dyn FnMut()) -> Result<String, String> {
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(500))
        .map_err(|e| format!("connect: {e}"))?;
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let line = format!(
        "{{\"protocol\":\"nebula.runtime\",\"version\":1,\"id\":\"toast-{}\",\"token\":\"{token}\",\"method\":\"window.focus\",\"params\":{params}}}\n",
        std::process::id()
    );
    stream.write_all(line.as_bytes()).map_err(|e| format!("write: {e}"))?;
    on_sent();
    let mut resp = String::new();
    BufReader::new(stream).read_line(&mut resp).map_err(|e| format!("read: {e}"))?;
    // 口令不对时 Pebrel 直接断开，不回包
    if resp.is_empty() {
        return Err("empty response (token rejected?)".into());
    }
    Ok(resp)
}

fn is_ok(resp: &str) -> bool {
    resp.contains("\"ok\":true")
}

fn json_u32(s: &str, key: &str) -> Option<u32> {
    let start = s.find(key)? + key.len();
    let digits: String = s[start..].trim_start().chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// 找该进程可见、无 owner 的顶层窗口；不在前台就拉过来。返回日志用的结果
fn raise_process_window(pid: u32) -> &'static str {
    struct Search {
        pid: u32,
        hwnd: Hwnd,
    }
    extern "system" fn each(hwnd: Hwnd, lparam: isize) -> i32 {
        let search = unsafe { &mut *(lparam as *mut Search) };
        let mut owner_pid = 0u32;
        unsafe { GetWindowThreadProcessId(hwnd, &mut owner_pid) };
        if owner_pid == search.pid
            && unsafe { IsWindowVisible(hwnd) } != 0
            && unsafe { GetWindow(hwnd, GW_OWNER) } == 0
        {
            search.hwnd = hwnd;
            return 0;
        }
        1
    }
    let mut search = Search { pid, hwnd: 0 };
    unsafe { EnumWindows(each, &mut search as *mut Search as isize) };
    let hwnd = search.hwnd;
    if hwnd == 0 {
        return "no-window";
    }
    unsafe {
        if IsIconic(hwnd) != 0 {
            ShowWindow(hwnd, SW_RESTORE);
        }
        let fg = GetForegroundWindow();
        if fg == hwnd {
            return "already";
        }
        // 挂到当前前台线程的输入队列，绕过前台锁
        let me = GetCurrentThreadId();
        let fg_thread = GetWindowThreadProcessId(fg, std::ptr::null_mut());
        if fg_thread != 0 {
            AttachThreadInput(me, fg_thread, 1);
        }
        let ok = SetForegroundWindow(hwnd);
        BringWindowToTop(hwnd);
        if fg_thread != 0 {
            AttachThreadInput(me, fg_thread, 0);
        }
        if ok != 0 { "raised" } else { "raise-failed" }
    }
}

fn run_vbs(uri: &str) {
    let Ok(exe) = std::env::current_exe() else { return };
    let vbs = exe.with_file_name("focus.vbs");
    let windir = std::env::var("WINDIR").unwrap_or_else(|_| "C:\\Windows".into());
    let _ = std::process::Command::new(format!("{windir}\\System32\\wscript.exe"))
        .arg(vbs)
        .arg(uri)
        .spawn();
}

fn log(msg: &str) {
    let Ok(temp) = std::env::var("TEMP") else { return };
    let path = format!("{temp}\\claude-toast-focus.log");
    let mut st = SystemTime::default();
    unsafe { GetLocalTime(&mut st) };
    let line = format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03} {msg}\r\n",
        st.year, st.month, st.day, st.hour, st.minute, st.second, st.millis
    );
    let is_new = !std::path::Path::new(&path).exists();
    let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) else { return };
    let mut bytes = Vec::with_capacity(line.len() * 2 + 2);
    if is_new {
        bytes.extend_from_slice(&[0xFF, 0xFE]);
    }
    for unit in line.encode_utf16() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    let _ = f.write_all(&bytes);
}
