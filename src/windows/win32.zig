//! Hand-written Win32 bindings used by the Windows engine (Stage 2).
//! Only the bits zclicker needs: the low-level mouse hook (WH_MOUSE_LL) for
//! input and SendInput for output. user32 is linked from build.zig.

const std = @import("std");

pub const HHOOK = *opaque {};
pub const HINSTANCE = ?*opaque {};
pub const HWND = ?*opaque {};
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const BOOL = c_int;
pub const DWORD = u32;

pub const WH_MOUSE_LL: c_int = 14;

pub const WM_LBUTTONDOWN: WPARAM = 0x0201;
pub const WM_LBUTTONUP: WPARAM = 0x0202;
pub const WM_RBUTTONDOWN: WPARAM = 0x0204;
pub const WM_RBUTTONUP: WPARAM = 0x0205;
pub const WM_MBUTTONDOWN: WPARAM = 0x0207;
pub const WM_MBUTTONUP: WPARAM = 0x0208;
pub const WM_XBUTTONDOWN: WPARAM = 0x020B;
pub const WM_XBUTTONUP: WPARAM = 0x020C;
pub const XBUTTON1: u16 = 0x0001;
pub const XBUTTON2: u16 = 0x0002;

pub const INPUT_MOUSE: DWORD = 0;
pub const MOUSEEVENTF_LEFTDOWN: DWORD = 0x0002;
pub const MOUSEEVENTF_LEFTUP: DWORD = 0x0004;
pub const MOUSEEVENTF_RIGHTDOWN: DWORD = 0x0008;
pub const MOUSEEVENTF_RIGHTUP: DWORD = 0x0010;
pub const MOUSEEVENTF_MIDDLEDOWN: DWORD = 0x0020;
pub const MOUSEEVENTF_MIDDLEUP: DWORD = 0x0040;

pub const POINT = extern struct { x: i32, y: i32 };
pub const MSLLHOOKSTRUCT = extern struct {
    pt: POINT,
    mouseData: DWORD,
    flags: DWORD,
    time: DWORD,
    dwExtraInfo: usize,
};
pub const MSG = extern struct {
    hwnd: HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};
pub const MOUSEINPUT = extern struct {
    dx: i32,
    dy: i32,
    mouseData: DWORD,
    dwFlags: DWORD,
    time: DWORD,
    dwExtraInfo: usize,
};
pub const INPUT = extern struct {
    type: DWORD,
    u: extern union { mi: MOUSEINPUT },
};

pub const HOOKPROC = *const fn (c_int, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub extern "user32" fn SetWindowsHookExW(idHook: c_int, lpfn: HOOKPROC, hmod: HINSTANCE, dwThreadId: DWORD) callconv(.winapi) ?HHOOK;
pub extern "user32" fn CallNextHookEx(hhk: ?HHOOK, nCode: c_int, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn UnhookWindowsHookEx(hhk: HHOOK) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.winapi) BOOL;
pub extern "user32" fn SendInput(cInputs: u32, pInputs: [*]INPUT, cbSize: c_int) callconv(.winapi) u32;

pub extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;
